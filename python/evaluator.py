from __future__ import annotations
import argparse
import re
from pathlib import Path
from typing import List, Tuple, Dict, Set

# -----------------------------
# Helpers
# -----------------------------

def read_text_lines(path: Path) -> List[str]:
    return path.read_text(encoding="utf-8", errors="ignore").splitlines(keepends=False)


def remove_duplicates_and_sort(nums: List[int]) -> List[int]:
    return sorted(set(int(n) for n in nums))


# -----------------------------
# Core logic (Python port of IAM2 evaluator) + SonarQube Generic Coverage XML output
# -----------------------------

class ESQLCoverageEvaluator:
    def __init__(self, trace_log: Path, esql_source: Path, report_file: Path,
                 pattern_file: Path = Path("tracelog.pattern"),
                 filter_modules_file: Path = Path("filterModules.txt"),
                 filter_funcs_file: Path = Path("filterFunctionProcedure.txt"),
                 sonar_coverage_xml: Path | None = None):
        self.trace_log = trace_log
        self.esql_source = esql_source
        self.report_file = report_file
        self.pattern_file = pattern_file
        self.filter_modules_file = filter_modules_file
        self.filter_funcs_file = filter_funcs_file
        self.sonar_coverage_xml = sonar_coverage_xml

        # Globals/aggregates analogous to the Perl script
        self.extracted_log_entries: List[Tuple[str, int, str]] = []  # (function, relative_line, statement)
        self.esql_schema_modules: List[str] = []
        self.function_counter: int = 0
        self.result_lines: List[str] = []
        self.esql_module_func_stats: Dict[str, Tuple[int, int, int, int]] = {}
        self.total_executed_lines: int = 0
        self.total_executable_lines: int = 0

        # SonarQube coverage map: file path -> line number -> covered(bool)
        self.sonar_coverage_map: Dict[str, Dict[int, bool]] = {}

        # Precompile regex pieces used multiple times
        self.re_comment_line = re.compile(r"^\d+:\s+--")
        self.re_block_comment_start = re.compile(r"^\d+:\s*/\*")
        self.re_block_comment_end_anywhere = re.compile(r"\*/\s*$")

        # Load optional filters
        self.modules_to_filter: Set[str] = set()
        if self.filter_modules_file.exists():
            self.modules_to_filter = {ln.strip() for ln in read_text_lines(self.filter_modules_file) if ln.strip()}
        self.funcs_to_filter: Set[str] = set()
        if self.filter_funcs_file.exists():
            self.funcs_to_filter = {ln.strip() for ln in read_text_lines(self.filter_funcs_file) if ln.strip()}

        # Pattern from tracelog.pattern (supports comments and multiple entries)
        if not self.pattern_file.exists():
            raise FileNotFoundError(f"Required pattern file not found: {self.pattern_file}")
        raw = self.pattern_file.read_text(encoding="utf-8", errors="ignore")
        lines = []
        for ln in raw.splitlines():
            s = ln.strip()
            if not s or s.startswith('#'):
                continue
            lines.append(s)
        if not lines:
            raise ValueError("tracelog.pattern contained no usable (non-comment) patterns")
        combined = "|".join(f"(?:{p})" for p in lines)
        self.trace_pattern = re.compile(combined, flags=re.IGNORECASE | re.VERBOSE)

        # Load inputs
        self.log_lines = read_text_lines(self.trace_log)
        self.esql_lines = read_text_lines(self.esql_source)

    # -------------------------
    # Phase 1: Scan source to discover schema and module names
    # -------------------------
    def _discover_schema_modules(self) -> None:
        current_schema = ""

        re_named_schema = re.compile(r"\bCREATE\s+SCHEMA\s+([A-Za-z0-9_.]+)\s+PATH", re.IGNORECASE)
        re_default_schema = re.compile(r"\bCREATE\s+SCHEMA\s+""\s+PATH", re.IGNORECASE)
        re_module = re.compile(r"\bCREATE\s+(?:COMPUTE|FILTER|DATABASE)\s+MODULE\s+(.+)$", re.IGNORECASE)

        for raw in self.esql_lines:
            line = raw.rstrip()
            m = re_named_schema.search(line)
            if m:
                current_schema = m.group(1).strip()
                self.esql_schema_modules.append(current_schema)
                continue
            if re_default_schema.search(line):
                current_schema = ""
                continue
            m2 = re_module.search(line)
            if m2:
                esql_module = m2.group(1).strip()
                esql_module = esql_module.split("&#xd;", 1)[0].strip()
                full = f"{current_schema}.{esql_module}" if current_schema else f".{esql_module}"
                self.esql_schema_modules.append(full)
        self.esql_schema_modules.append("")
        self.esql_schema_modules = sorted(set(self.esql_schema_modules))

    # -------------------------
    # Phase 2: Extract executed statements from trace log
    # -------------------------
    def _extract_from_log(self) -> None:
        for line in self.log_lines:
            m = self.trace_pattern.search(line)
            if not m:
                continue
            # Prefer named groups if present
            gd = m.groupdict()
            function = (gd.get('func') or (m.group(1) if m.lastindex and m.lastindex >= 1 else '') or '').strip()
            relative_line = (gd.get('line') or (m.group(2) if m.lastindex and m.lastindex >= 2 else '') or '').strip()
            if not function or not relative_line:
                continue
            try:
                rel = int(float(relative_line))
            except Exception:
                continue

            # Extract statement between the first and last quotes before ' at '
            stmt = ""
            try:
                at_idx = line.rfind(" at ")
                # Find last single quote before ' at '
                last_q = line.rfind("'", 0, at_idx)
                # Find first single quote before that
                first_q = line.find("'", 0, last_q)
                if first_q != -1 and last_q != -1 and last_q > first_q:
                    stmt = line[first_q + 1:last_q]
            except ValueError:
                stmt = ""
            stmt = stmt.strip()

            schema_and_module = function.rsplit(".", 1)[0] if "." in function else ""

            if function not in (".statusACTIVE", ".statusINACTIVE"):
                for known in self.esql_schema_modules:
                    if known == schema_and_module:
                        self.extracted_log_entries.append((function, rel, stmt))
                        break

    # -------------------------
    # Phase 3: Parse ESQL and accumulate coverage per function/procedure
    # -------------------------
    def _process_esql(self) -> None:
        current_schema = ""
        current_module = ""
        begin_filtered_module = False
        in_func_proc = False
        function_indexed: List[str] = []
        function_line_counter = 1
        esql_schema_module_function = ""
        function_body_start_file_line = 0  # absolute file line number of "1:" within function_indexed

        re_named_schema = re.compile(r"\bCREATE\s+SCHEMA\s+([A-Za-z0-9_.]+)\s+PATH", re.IGNORECASE)
        re_default_schema = re.compile(r"\bCREATE\s+SCHEMA\s+""\s+PATH", re.IGNORECASE)
        re_module = re.compile(r"\bCREATE\s+(?:COMPUTE|FILTER|DATABASE)\s+MODULE\s+(.+)$", re.IGNORECASE)
        re_end_module = re.compile(r"\bEND\s+MODULE;", re.IGNORECASE)
        re_func_or_proc = re.compile(r"\bCREATE\s+(?:FUNCTION|PROCEDURE)\s+(\w+)\s*\(", re.IGNORECASE)
        re_end_stmt_variants = re.compile(r"(^|\s)END\s*;\s*$", re.IGNORECASE)

        seen_atomic_block = False
        seen_case_block = False

        for file_line_no, raw in enumerate(self.esql_lines, start=1):
            line = raw.rstrip("\n\r")

            m = re_named_schema.search(line)
            if m:
                current_schema = m.group(1).strip()
                current_module = ""
                in_func_proc = False
                function_line_counter = 1
                function_indexed = []
                continue
            if re_default_schema.search(line):
                current_schema = ""
                current_module = ""
                in_func_proc = False
                function_line_counter = 1
                function_indexed = []
                continue

            m = re_module.search(line)
            if m:
                function_line_counter = 1
                current_module = m.group(1).strip()
                current_module = current_module.split("&#xd;", 1)[0].strip()
                begin_filtered_module = current_module in self.modules_to_filter
                continue

            if re_end_module.search(line):
                begin_filtered_module = False
                current_module = ""
                continue

            if re.search(r"\bBEGIN\s+ATOMIC\b", line, re.IGNORECASE):
                seen_atomic_block = True
            if re.search(r"\bCASE\b", line):
                seen_case_block = True
            if re.search(r"\bEND\s+CASE\s*;", line, re.IGNORECASE):
                seen_case_block = False

            m = re_func_or_proc.search(line)
            if m:
                name = m.group(1)
                if begin_filtered_module or (name in self.funcs_to_filter):
                    in_func_proc = False
                    function_indexed = []
                    function_line_counter = 1
                    continue
                in_func_proc = True
                self.function_counter += 1
                function_indexed = []
                function_line_counter = 1
                function_body_start_file_line = file_line_no + 1  # first body line (next line) will be numbered 1
                if current_schema:
                    if current_module:
                        esql_schema_module_function = f"{current_schema}.{current_module}.{name}"
                    else:
                        esql_schema_module_function = f"{current_schema}.{name}"
                else:
                    if current_module:
                        esql_schema_module_function = f".{current_module}.{name}"
                    else:
                        esql_schema_module_function = f".{name}"
                continue

            if in_func_proc:
                function_indexed.append(f"{function_line_counter}: {line}")
                function_line_counter += 1

            if re_end_stmt_variants.search(line):
                if seen_atomic_block:
                    seen_atomic_block = False
                    continue
                if seen_case_block:
                    seen_case_block = False
                    continue

                if in_func_proc:
                    func_exec_lines = self._collect_executed_lines_for(esql_schema_module_function,
                                                                      function_indexed)
                    stats, rendered, executable_rel, executed_rel = self._calculate_and_store_function_indicator(
                        esql_schema_module_function,
                        function_indexed,
                        func_exec_lines,
                    )
                    self.esql_module_func_stats[esql_schema_module_function] = stats
                    self.result_lines.extend(rendered)

                    # Update SonarQube coverage map using absolute file lines
                    file_key = str(self.esql_source)
                    file_map = self.sonar_coverage_map.setdefault(file_key, {})
                    for n in sorted(executable_rel):
                        abs_line = function_body_start_file_line + n - 1
                        covered = (n in executed_rel)
                        # If line already present, once covered, keep covered=True
                        file_map[abs_line] = file_map.get(abs_line, False) or covered

                    in_func_proc = False
                    function_line_counter = 1
                    function_indexed = []
                    esql_schema_module_function = ""
                else:
                    esql_schema_module_function = ""

    # -------------------------
    # Helpers for phase 3
    # -------------------------
    def _collect_executed_lines_for(self, esql_key: str, function_indexed: List[str]) -> List[int]:
        exec_lines: List[int] = []
        for func, rel, stmt in self.extracted_log_entries:
            if func.lower().endswith(esql_key.lower()):
                exec_lines.append(rel)
                exec_lines.extend(self._add_BEGIN_tail_and_header(stmt, function_indexed))
                exec_lines.extend(self._add_atomic_tail_and_header(stmt, function_indexed))
                exec_lines.extend(self._add_tail("IF", "END IF", function_indexed, start_line=rel, middle="ELSE"))
                exec_lines.extend(self._add_named_tail("IF", "END IF", function_indexed, start_line=rel, middle="ELSE"))
                exec_lines.extend(self._add_tail("WHILE", "END WHILE", function_indexed, start_line=rel))
                exec_lines.extend(self._add_named_tail("WHILE", "END WHILE", function_indexed, start_line=rel))
                exec_lines.extend(self._add_tail("LOOP", "END LOOP", function_indexed, start_line=rel))
                exec_lines.extend(self._add_named_tail("LOOP", "END LOOP", function_indexed, start_line=rel))
                exec_lines.extend(self._add_tail("CASE", "END CASE", function_indexed, start_line=rel, middle="WHEN"))
                exec_lines.extend(self._add_named_tail("CASE", "END CASE", function_indexed, start_line=rel, middle="WHEN"))
                exec_lines.extend(self._add_tail("REPEAT", "END REPEAT", function_indexed, start_line=rel))
                exec_lines.extend(self._add_named_tail("REPEAT", "END REPEAT", function_indexed, start_line=rel))
                exec_lines.extend(self._add_tail("FOR", "END FOR", function_indexed, start_line=rel))
                exec_lines.extend(self._add_named_tail("FOR", "END FOR", function_indexed, start_line=rel))
                exec_lines.extend(self._add_tail("BEGIN ATOMIC", "END", function_indexed, start_line=rel))
                exec_lines.extend(self._add_named_tail("BEGIN ATOMIC", "END", function_indexed, start_line=rel))
        return remove_duplicates_and_sort(exec_lines)

    def _parse_indexed_line(self, s: str) -> Tuple[int, str]:
        try:
            num_str, content = s.split(":", 1)
            return int(num_str.strip()), content.lstrip()
        except Exception:
            return -1, s

    def _find_from_rel(self, function_indexed: List[str], start_line_num: int):
        for s in function_indexed[start_line_num - 1:]:
            n, content = self._parse_indexed_line(s)
            yield n, content

    def _add_BEGIN_tail_and_header(self, stmt: str, function_indexed: List[str]) -> List[int]:
        out = []
        if re.match(r"^BEGIN\b.*\bEND\b", stmt, flags=re.IGNORECASE):
            out.append(1)
            for s in reversed(function_indexed):
                n, content = self._parse_indexed_line(s)
                if re.search(r"^END\s*;", content, flags=re.IGNORECASE):
                    out.append(n)
                    break
        return out

    def _add_atomic_tail_and_header(self, stmt: str, function_indexed: List[str]) -> List[int]:
        out = []
        m = re.match(r"^(.*)\s*:\s*.*ATOMIC.*END", stmt, flags=re.IGNORECASE)
        if m:
            label = m.group(1).strip()
            for s in reversed(function_indexed):
                n, content = self._parse_indexed_line(s)
                if re.search(rf"^END\s+{re.escape(label)}\s*;", content, flags=re.IGNORECASE):
                    out.append(n)
                    break
        return out

    def _add_tail(self, begin: str, end: str, function_indexed: List[str], *, start_line: int, middle: str = "") -> List[int]:
        out = []
        tag_counter = 0
        in_block_comment = False
        begin_re = re.compile(rf"^{begin}\b", re.IGNORECASE)
        end_re = re.compile(rf"^{end}\s*;", re.IGNORECASE)
        middle_re = re.compile(rf"^{middle}\b", re.IGNORECASE) if middle else None
        for n, content in self._find_from_rel(function_indexed, start_line):
            if self.re_comment_line.search(f"{n}: {content}"):
                continue
            if not in_block_comment and self.re_block_comment_start.search(f"{n}: {content}"):
                in_block_comment = True
            if in_block_comment:
                if self.re_block_comment_end_anywhere.search(content):
                    in_block_comment = False
                continue
            if begin_re.search(content):
                tag_counter += 1
                continue
            if middle_re and middle_re.search(content) and tag_counter == 1:
                out.append(n)
                continue
            if end_re.search(content):
                tag_counter -= 1
                if tag_counter == 0:
                    out.append(n)
                    break
        return out

    def _add_named_tail(self, begin: str, end: str, function_indexed: List[str], *, start_line: int, middle: str = "") -> List[int]:
        out = []
        try:
            start_line_text = function_indexed[start_line - 1].split(":", 1)[1].strip()
        except Exception:
            start_line_text = ""
        m = re.match(r"^(\w+)\s*:\s*" + re.escape(begin), start_line_text, re.IGNORECASE)
        if not m:
            return out
        label = m.group(1)
        tag_counter = 0
        in_block_comment = False
        begin_re = re.compile(rf"^{re.escape(label)}\s*:\s*{begin}\b", re.IGNORECASE)
        end_re = re.compile(rf"^{end}\s+{re.escape(label)}\s*;", re.IGNORECASE)
        middle_re = re.compile(rf"^{middle}\b", re.IGNORECASE) if middle else None

        for n, content in self._find_from_rel(function_indexed, start_line):
            if self.re_comment_line.search(f"{n}: {content}"):
                continue
            if not in_block_comment and self.re_block_comment_start.search(f"{n}: {content}"):
                in_block_comment = True
            if in_block_comment:
                if self.re_block_comment_end_anywhere.search(content):
                    in_block_comment = False
                continue
            if begin_re.search(content):
                tag_counter += 1
                continue
            if middle_re and middle_re.search(content) and tag_counter == 1:
                out.append(n)
                continue
            if end_re.search(content):
                tag_counter -= 1
                if tag_counter == 0:
                    out.append(n)
                    break
        return out

    def _calculate_and_store_function_indicator(self, esql_key: str, function_indexed: List[str], executed_lines: List[int]):
        rendered: List[str] = []
        rendered.append(f"\nESQL Function / Procedure {self.function_counter}: '{esql_key}'\n\n")
        function_executable_lines = 0
        function_non_executable_lines = 0
        function_comment_lines = 0

        exec_set = set(executed_lines)

        many_lines_comment = False
        current_cmd_not_finished = False
        current_cmd_is_case = False

        # New: track executable vs executed (relative) for SonarQube mapping
        executable_rel: Set[int] = set()
        executed_rel: Set[int] = set()

        for s in function_indexed:
            n, content = self._parse_indexed_line(s)
            is_comment_line = content.strip().startswith("--")
            is_blank_line = (content.strip() == "")
            is_block_comment_start = content.strip().startswith("/*")
            is_block_comment_end = content.strip().endswith("*/")

            if many_lines_comment:
                rendered.append(" " + s)
                function_comment_lines += 1
                if is_block_comment_end:
                    many_lines_comment = False
                continue

            if current_cmd_not_finished:
                if is_comment_line or is_blank_line or is_block_comment_start:
                    rendered.append(" " + s)
                    if is_comment_line or is_block_comment_start:
                        function_comment_lines += 1
                        if is_block_comment_start and not is_block_comment_end:
                            many_lines_comment = True
                    else:
                        function_non_executable_lines += 1
                else:
                    rendered.append("[x] " + s)
                    function_executable_lines += 1
                    executable_rel.add(n)
                    executed_rel.add(n)
                    ended = False
                    stripped = content.rstrip()
                    if current_cmd_is_case:
                        if stripped.endswith(";"):
                            ended = True
                    else:
                        if stripped.endswith(";") or re.search(r"\b(THEN|DO|BEGIN)\b$", stripped, re.IGNORECASE):
                            ended = True
                    if ended:
                        current_cmd_not_finished = False
                        current_cmd_is_case = False
                continue

            if n in exec_set:
                rendered.append("[x] " + s)
                function_executable_lines += 1
                executable_rel.add(n)
                executed_rel.add(n)
                core = s
                dashdash = core.find("--")
                if dashdash > 0:
                    core = core[:dashdash]
                core_content = core.split(":", 1)[1].rstrip() if ":" in core else core
                if not re.search(r";\s*$|\b(THEN|ELSE|BEGIN|DO)\s*$", core_content, re.IGNORECASE):
                    current_cmd_not_finished = True
                    if re.search(r"\bCASE\b", core_content, re.IGNORECASE):
                        current_cmd_is_case = True
                continue

            if not is_comment_line and not is_blank_line and not is_block_comment_start and not content.strip().startswith("&#xd;"):
                rendered.append("[ ] " + s)
                function_executable_lines += 1
                executable_rel.add(n)
            else:
                rendered.append(" " + s)
                if is_comment_line or is_block_comment_start:
                    function_comment_lines += 1
                    if is_block_comment_start and not is_block_comment_end:
                        many_lines_comment = True
                else:
                    function_non_executable_lines += 1

        executed_count = len(executed_lines)
        stats = (executed_count, function_executable_lines, function_non_executable_lines, function_comment_lines)
        return stats, rendered, executable_rel, executed_rel

    # -------------------------
    # Phase 4: Write reports
    # -------------------------
    def write_report(self) -> None:
        from datetime import datetime
        now = datetime.now()
        with self.report_file.open("w", encoding="utf-8") as f:
            f.write(f"ESQL Source Code: {self.esql_source}\n")
            f.write(f"User Trace Log : {self.trace_log}\n")
            f.write(f"Execution time : {now:%Y-%m-%d %H:%M:%S}\n\n")
            f.write("IAM2 version : 1.0.6\n")
            f.write("-------------------------\n")
            f.write("Overview of Code Coverage\n")
            f.write("-------------------------\n")
            total_functions = self.function_counter
            f.write(f"Total Functions & Procedures: {total_functions}\n\n")

            total_executed = 0
            total_executable = 0
            for function in sorted(self.esql_module_func_stats.keys(), key=str.lower):
                executed, executable, nonexec, comments = self.esql_module_func_stats[function]
                total_lines = executable + nonexec + comments
                if executable > 0:
                    code_coverage = f"{(executed / executable) * 100:5.1f}"
                    percent_comment = f"{(comments / (executable + comments) * 100):5.1f}" if (executable + comments) > 0 else "  0.0"
                else:
                    code_coverage = "  0.0"
                    percent_comment = "  0.0"
                f.write(f"'{function}'\n")
                f.write(f"Lines : {total_lines} ({comments} comment and {nonexec} blank lines)\n")
                f.write(f"Executed Lines : {executed} of {executable} executable lines\n")
                f.write(f"Percent comment : {percent_comment}%\n")
                f.write(f"Code coverage : {code_coverage}%\n\n")
                total_executed += executed
                total_executable += executable

            total_coverage = (total_executed / total_executable * 100) if total_executable > 0 else 0.0
            f.write(f"Total Executed Lines : {total_executed} of {total_executable} executable lines\n")
            f.write(f"Total Code Coverage : {total_coverage:.1f}%\n\n")
            f.write("------------------------\n")
            f.write("Details of Code Coverage\n")
            f.write("------------------------\n")
            f.write("[x] line was executed\n")
            f.write("[ ] line was not executed\n")
            f.write(" line is comment or blank line\n")
            for line in self.result_lines:
                f.write(line + ("" if line.endswith("\n") else "\n"))

        if self.sonar_coverage_xml:
            self._write_sonar_generic_coverage(self.sonar_coverage_xml)

    def _write_sonar_generic_coverage(self, out_path: Path) -> None:
        """Write SonarQube Generic Test Coverage XML (coverage version=1).
        See: https://docs.sonarsource.com/sonarqube-server/latest/analyzing-source-code/test-coverage/generic-test-data/
        """
        out_path = Path(out_path)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        lines = []
        lines.append('<coverage version="1">')
        for file_path in sorted(self.sonar_coverage_map.keys()):
            lines.append(f'  <file path="{self._xml_escape(file_path)}">')
            for ln in sorted(self.sonar_coverage_map[file_path].keys()):
                covered = 'true' if self.sonar_coverage_map[file_path][ln] else 'false'
                lines.append(f'    <lineToCover lineNumber="{ln}" covered="{covered}"/>')
            lines.append('  </file>')
        lines.append('</coverage>')
        out_path.write_text("\n".join(lines) + "\n", encoding='utf-8')

    @staticmethod
    def _xml_escape(text: str) -> str:
        return (text.replace('&', '&amp;')
                    .replace('"', '&quot;')
                    .replace("'", '&apos;')
                    .replace('<', '&lt;')
                    .replace('>', '&gt;'))

    # -------------------------
    # Public API
    # -------------------------
    def run(self) -> None:
        self._discover_schema_modules()
        self._extract_from_log()
        self._process_esql()
        self.write_report()


# -----------------------------
# CLI
# -----------------------------

def main():
    parser = argparse.ArgumentParser(description="Evaluate ESQL code coverage from IBM Integration Bus/ACE user trace logs (Python port of IAM2 evaluator). Optionally writes SonarQube Generic Coverage XML.")
    parser.add_argument("userTraceFile", type=Path, help="The trace file (UserTrace or ServiceTrace)")
    parser.add_argument("sourceCodeFile", type=Path, help="The ESQL source/CMF file")
    parser.add_argument("reportFileName", type=Path, help="Output text report")
    parser.add_argument("--pattern", type=Path, default=Path("tracelog.pattern"), help="Path to tracelog.pattern (required)")
    parser.add_argument("--filter-modules", type=Path, default=Path("filterModules.txt"), help="Optional file listing modules to filter out")
    parser.add_argument("--filter-funcs", type=Path, default=Path("filterFunctionProcedure.txt"), help="Optional file listing procedures/functions to filter out")
    parser.add_argument("--sonar-coverage-xml", type=Path, default=None, help="Optional path to write SonarQube Generic Test Coverage XML (coverage version=1)")

    args = parser.parse_args()

    evaluator = ESQLCoverageEvaluator(
        trace_log=args.userTraceFile,
        esql_source=args.sourceCodeFile,
        report_file=args.reportFileName,
        pattern_file=args.pattern,
        filter_modules_file=args.filter_modules,
        filter_funcs_file=args.filter_funcs,
        sonar_coverage_xml=args.sonar_coverage_xml,
    )
    evaluator.run()
    print(f"\nReport has been written to {args.reportFileName}")
    if args.sonar_coverage_xml:
        print(f"SonarQube Generic Coverage XML written to {args.sonar_coverage_xml}")
    print("\nSupportPac IAM2, Version 1.0.6 (Python port)")


if __name__ == "__main__":
    main()
