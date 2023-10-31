#!/usr/local/bin/perl
####################################################################
#  Version: 1.0.6                                                  #
#  Author:  Torsten Schaefer                                       #
#           Matthias Kabala                                        #
#  Date:    07.10.2017                                             #
#                                                                  #
####################################################################
#                                                                  #
#  Statement:   Licensed Materials - Property of IBM               #
#                                                                  #
#               5748-XX8                                           #
#               (C) Copyright IBM Corp. 2008                       #
#                                                                  #
####################################################################

# import pattern of the tracelog file
# this pattern file is used to evaluate trace log statements
open(READ, "tracelog-non-en_US.pattern") or die "Cannot open file: $!\n";
	$pattern = <READ>;
close(READ);

# exit if number of command line parameters is not correct
if ($#ARGV + 1 ne 3) {
	print "\nusage: " . $0 . " <userTraceFile> <sourceCodeFile> <reportFileName>\n";
	print "\nwhere";
	print "\n <userTraceFile>  = the trace file from the message broker";
	print "\n <sourceCodeFile> = the name of the source file (CMF file from the BAR file is recommended)";
	print "\n <reportFileName> = the name of the report file (will be created if not exist or overwritten)\n";
	print "\nSupport Pac IAM2, Version 1.0.6\n";
	exit;
}

# get command line parameters
$logFileName = $ARGV[0];
$esqlFileName = $ARGV[1];
$reportFile = $ARGV[2];

# hidden feature
# store names of modules which should be filtered to array
# this file is optional and does not need to exist
open(READ,'filterModules.txt ');
@modulesToFilterOut = <READ>;
close(READ);

# hidden feature
# store names of procedures and functions which should be filtered to array
# this file is optional and does not need to exist
open(READ,'filterFunctionProcedure.txt ');
@proceduresToFilterOut = <READ>;
close(READ);

# store tracelogfile to array
open(READ,$logFileName) or die "Cannot open file: $!\n";
@logFileLines = <READ>;
close(READ);

# store sourcecodefile to array
open(READ,$esqlFileName) or die "Cannot open file: $!\n";
@esqlFileLines = <READ>;
close(READ);

# traverse each line of sourcecodefile for compute, database and filter nodes
# result: array @esqlModules with names of all ESQL nodes in source code file
foreach my $line (@esqlFileLines) {
	# search for schema
	# named schema is of pattern: 'CREATE SCHEMA <schema_name> PATH'
	if($line =~ /(?:CREATE|BROKER)\s+SCHEMA\s+([\w\.]+)\s+PATH/i) {
		$esqlSchema = $1;
			# trim
			$esqlSchema =~ s/^\s+//;
			$esqlSchema =~ s/\s+$//;
		# add schema only (treated as empty module in schema) - duplicates will be removed later
		push(@esqlSchemaModules, $esqlSchema);
	}
	# default schema is of pattern: 'CREATE SCHEMA "" PATH'
	if($line =~ /(?:CREATE|BROKER)\s+SCHEMA\s+""\s+PATH/i) {
		$esqlSchema = '';
		# No empty module for default schema, will be added at the end.
		# skip this line
		next;
	}
	# search for compute, filter or database nodes
	# first delete &#xd; if exist (which is 0d0a CRLF)
	if($line =~ /CREATE\s+(?:COMPUTE|FILTER|DATABASE)\s+MODULE\s+(.+)/i) {
		# store name of compute, filter or database module to array @esqlModules
		$esqlModule = $1;
			$esqlModule =~ s/^\s+//;
			$esqlModule =~ s/\s+$//;
		$idx = index($esqlModule, '&#xd;');
		if($idx > -1) {
			$esqlModule = substr($esqlModule, 0, $idx);
		}
		$esqlModule = $esqlSchema . '.' . $esqlModule;
		push(@esqlSchemaModules, $esqlModule);
		#print "\nnode: $esqlModule\n";
	}
}
# as functions / procedures w/o modules could be included in source file, we have
# to add a empty module
push(@esqlSchemaModules, '');
@esqlSchemaModules = removeDuplicatesAndSort(@esqlSchemaModules);

$moduleCounter = 0;
  
# traverse every line of logfile for execute statements or evaluation expression statements 
# store these lines in array @extractedLogFile.
foreach my $line (@logFileLines) {
		# use imported regex pattern for every line. extract information about
		# - called esql node with interface eg. <IF_INTEFACE_TEST>.<COMPUTE_NODE>
		# - function or procedure of this node
		# - line number of executed statement relative to function or procedure
		# - the full statement
		$line =~ /$pattern/i;

		# function = <schema_name>.<module_name.><function/procedure_name>
		$function = $1;
			# trim
			$function =~ s/^\s+//;
			$function =~ s/\s+$//;
			
		# relativeLine
		$relativeLine = $2; 
			# trim
			$relativeLine =~ s/^\s+//;
			$relativeLine =~ s/\s+$//;

		# esql statement
		# substr(<source_string>, <index_of_start>, <length_of_substring>)
		$statement = substr($line, 
							index($line, '\'\'') + 2 ,							                            # index after first occurence of ''
#							((rindex($line, '\'\'', index($line, ' at ')) - 4) - index($line, '\'\'') + 2)	# length of string between first occurence of '' and last occurence of '' before the ' at ' string
							((rindex($line, '\'\'') - 4) - index($line, '\'\'') + 2)	# length of string between first occurence of '' and last occurence of '' 
		);
			# trim
			$statement =~ s/^\s+//;
			$statement =~ s/\s+$//;

		# if schema and/or module exists in function we calculate it here
		$schemaAndModule = '';
		if (rindex($function, '.') > -1)
		{
			# schema and/or module does exist
			# function = <schema_name>.<function/procedure_name>
			#         or <schema_name>.<module_name.><function/procedure_name>
			$schemaAndModule = substr($function, 0, rindex($function, '.'));
		} else {
			# no schema and module exist
			# function = <function/procedure_name>
			$schemaAndModule = '';
		}
		
		foreach my $esqlSchemaModuleName(@esqlSchemaModules) {
			# add current line just if statement doesn't belong to SUB-FLOW 
			if($esqlSchemaModuleName eq $schemaAndModule) {
				$moduleCounter++;
				# don't include statusACTIVE and statusINACTIVE messages
				# because they will be interpreted as function names.
				# reason: this script searchs for notation "<esqlModule>.<function>"
				# in user trace log so "<esqlModule>.statusACTIVE" will be
				# interpreted wrong.
				if($function ne ".statusACTIVE" and $function ne ".statusINACTIVE") { 
					push(@extractedLogFile, "$function;$relativeLine;$statement\n");
				}
			}
		}
}

# counter for functions and procedures
$functionCounter = 0;

# boolean helper var ('0' = false; '1' = true);
$beginModule = '0';
$beginFilteredOutModule = '0';
$beginFunctionProcedure = '0';
$esqlModule = '';
$esqlSchema = '';
$caseStatement = '0';
$atomic = '0';

# counter for lines of every function
$functionLineCounter = 1;

# parse every line of esql code
foreach my $line (@esqlFileLines) {
	# search for schema
	# named schema is of pattern: 'CREATE SCHEMA <schema_name> PATH'
	if($line =~ /(?:CREATE|BROKER)\s+SCHEMA\s+([\w\.]+)\s+PATH/i) {
		$esqlSchema = $1;
			# trim
			$esqlSchema =~ s/^\s+//;
			$esqlSchema =~ s/\s+$//;
		# reset esqlModule and functionName
		$esqlModule = '';
		$functionName = '';
		# reset line counter
		$functionLineCounter = 1;
		# skip this line
		next;
	}
	# default schema is of pattern: 'CREATE SCHEMA "" PATH'
	if($line =~ /(?:CREATE|BROKER)\s+SCHEMA\s+""\s+PATH/i) {
		$esqlSchema = '';
		# reset esqlModule and functionName
		$esqlModule = '';
		$functionName = '';
		# reset line counter
		$functionLineCounter = 1;
		# skip this line
		next;
	}
	# search for compute, filter or database nodes
	if($line =~ /CREATE\s+(?:COMPUTE|FILTER|DATABASE)\s+MODULE\s+(.+)/i) {
		# reset line counter
		$functionLineCounter = 1;
		# store information about current node in var $esqlModule
		$esqlModule = $1;
			# trim
			$esqlModule =~ s/^\s+//;
			$esqlModule =~ s/\s+$//;
		$idx = index($esqlModule, '&#xd;');
		if($idx > -1) {
			$esqlModule = substr($esqlModule, 0, $idx);
		}

		# filter out modules of generic components
		$filterIt = '0';
		foreach my $entry (@modulesToFilterOut) 
		{
			if (substr($entry, 0, length($entry)-1) eq $1) {
				$filterIt = '1';
			}
		}
		if ($filterIt == '1') {
			$beginFilteredOutModule = '1';
			# jump to next cicle of foreach loop
			next;
		} else {
			# another module found
			$esqlModuleCounter++;
			$beginModule = '1';
			# reset line counter
			$functionLineCounter = 1;
			# jump to next cicle of foreach loop
			next;
		}
	}
	if($line =~ /END\s+MODULE;/i) 
	{
		# reset module
		$beginFilteredOutModule = '0';
		$beginModule = '0';
		$esqlModule = '';
	}
if($line =~ /\s+BEGIN\s+ATOMIC\s+/)
{
	# ATOMIC statement - ended by just END, therefore special treatment needed
	$atomic = '1';
}
if($line =~ /\s+CASE\s+/)
{
	# CASE statement - could be ended by just END instead of END CASE, therefore special treatment needed
	$caseStatement = '1';
}
if($line =~ /\s+END\s+CASE\s*;/)
{
	# CASE statement - could be ended by just END instead of END CASE, therefore special treatment needed
	$caseStatement = '0';
}
	# ?: non capturing group. whats in these brackets will not be stored to var $1
    # end bracket could be on one of the next lines
	if($line =~ /CREATE\s+(?:FUNCTION|PROCEDURE)\s+([\w]+)\s*\(/i)
	{
		# reset line counter
		$functionLineCounter = 1;
		$dummy = $1;
		$filterIt = $beginFilteredOutModule;
		foreach my $entry (@proceduresToFilterOut) 
		{
			if ($1 =~ substr($entry, 0, length($entry)-1)) {
				$filterIt = '1';
			}
		}
		if ($filterIt == '1') {
			next;
		} else {
			# mark that function or procedure was found
			# the following lines belong to one function or procudure
			#$beginFunction = '1';
			$functionName = $dummy;
			# $esqlModuleAndFunction = "$esqlModule.$functionName";
			if (length($esqlSchema) > 0){
				if (length($esqlModule) > 0) {
					$esqlSchemaAndModuleAndFunction = "$esqlSchema.$esqlModule.$functionName";
				} else {
					$esqlSchemaAndModuleAndFunction = "$esqlSchema.$functionName";
				}
			} else {
				if (length($esqlModule) > 0) {
					$esqlSchemaAndModuleAndFunction = ".$esqlModule.$functionName";
				} else {
					$esqlSchemaAndModuleAndFunction = ".$functionName";
				}
			}
			# print "\nesqlSchemaAndModuleAndFunction: $esqlSchemaAndModuleAndFunction";
			# print "\nbeginFilteredOutModule: $beginFilteredOutModule";
			# reset array for current function
			@functionIndexed = ();
			if($beginFilteredOutModule == '0') {
				# another function or procedure found
				$functionCounter++;
				$beginFunctionProcedure = '1';
			}
		}
	}
	if($beginFunctionProcedure) {
		# index every line with a line number (beginning with 1)
		push(@functionIndexed, "$functionLineCounter: $line");
		# increase for next line
		$functionLineCounter++;
	}
	# if line contains an END statement --> function or procedure over
	if($line =~ /\s+END\s*;\s*/i
	   or $line =~ /\s+END;&#xd;\s*/i
	   or $line =~ /\s+END;\s+&#xd;\s*/i
	   or $line =~ /^END;\s*/i
	   or $line =~ /^END;&#xd;\s*/i
	   or $line =~ /^END;\s+&#xd;\s*/i
	   or $line =~ /^END\s+;\s*/i
	   or $line =~ /^END\s+;&#xd;\s*/i
	   or $line =~ /^END\s+;\s+&#xd;\s*/i
	   or $line =~ /\s+END\s+;\s*/i
	   or $line =~ /\s+END\s+;&#xd;\s*/i
	   or $line =~ /\s+END\s+;\s+&#xd;\s*/i) 
	{
if($atomic) 
{
	$atomic = '0';
	next;
}
if($caseStatement) 
{
	$caseStatement = '0';
	next;
}
		if ($beginFunctionProcedure) 
		{
			# reset marker for next function or procedure
			$beginFunctionProcedure = '0';
			# reset line counter
			$functionLineCounter = 1;
			# reset helper array that stores linenumbers of executed lines
			@functionExecutedLines = ();
			
			# seach in all sorted lines for lines that belong to a compute function
			foreach my $line (@extractedLogFile) 
			{
				# restore information for every line of array @extractedLogFile
				@arrayLine = split(';', $line);
				$function = $arrayLine[0];
				$relativeLine = $arrayLine[1];
				$statement = $arrayLine[2];
				# $function = <schema_name>.<module_name.><function_name/procedure_name>
				if($function =~ /$esqlSchemaAndModuleAndFunction$/i) 
				{
					push(@functionExecutedLines, $relativeLine);

					#add end tags to begin tags manually
					#because information is not stored in user trace log files
					addBEGINtailAndHeader();
					addAtomicTailAndHeader();
					addTail("IF", "END IF", "ELSE");
					addNamedTail("IF", "END IF", "ELSE");
					addTail("WHILE", "END WHILE");
					addNamedTail("WHILE", "END WHILE");
					addTail("LOOP", "END LOOP");
					addNamedTail("LOOP", "END LOOP");
					addTail("CASE", "END CASE", "WHEN");
					addNamedTail("CASE", "END CASE", "WHEN");
					addTail("REPEAT", "END REPEAT");
					addNamedTail("REPEAT", "END REPEAT");
					addTail("FOR", "END FOR");
					addNamedTail("FOR", "END FOR");
					addTail("BEGIN ATOMIC", "END");
					addNamedTail("BEGIN ATOMIC", "END");
				}
			}
			
			# remove duplicate entries from executed lines and sort them ascending
			@functionExecutedLines = removeDuplicatesAndSort(@functionExecutedLines);
			
			# write current function with indicator to temporary array.
			# indicator show in output whether line was executed or not.
			calculateAndStoreFunctionIndicator();
		} 
		else 
		{
			#end of node
			#reset node
			$esqlSchemaAndModuleAndFunction = '';
		}
	}
}

# create report
writeAndCalculateReportFile();
print "\nReport has been written to $reportFile\n";
print "\nSupportPac IAM2, Version 1.0.6\n";

### SUBROUTINES ###

# remove duplicates from an array and sort linenumbers ascending
sub removeDuplicatesAndSort() {
	my %hash = ();
	my @new_array = ();
	
	# get array from parameters
	my @array = @_;
	my $size = $array;
	
	# use a hash to remove duplicates
	foreach my $i (@array) {
		$hash{$i} = 'yes';
	}
	while (($key, $value) = each(%hash)){
		 push(@new_array, $key);
	}
	
	# sort array with numerical compare
	@array = sort {$a <=> $b} @new_array;
	
	# return sorted array
	return @array;	
}

sub addBEGINtailAndHeader() {
	# add END line to executed lines if BEGIN is found
	if($statement =~ /^BEGIN ... END/i) {
		# add header CREATE FUNCTION or CREATE PROCEDURE. must be first line
		push(@functionExecutedLines, 1);
		# seach for the END tag. i > 0: cannot be first line
		for(my $i = $#functionIndexed; $i > 0; $i--) {
			$functionIndexedLine = $functionIndexed[$i];
			if($functionIndexedLine =~ /(^\d+):\s*END\s*;/i) {
				push(@functionExecutedLines, $1);
				last;
			}
		}
	}
}

sub addAtomicTailAndHeader() {
	# add END line to executed lines if BEGIN is found
	if($statement =~ /^(.*)\s+:.*ATOMIC... END/) {
		# seach for the END tag. i > 0: cannot be first line
		$atomicLabel = $1;
		for(my $i = $#functionIndexed; $i > 0; $i--) {
			$functionIndexedLine = $functionIndexed[$i];
			if($functionIndexedLine =~ /(^\d+):\s+END\s+$atomicLabel\s*;/i) {
				push(@functionExecutedLines, $1);
				last;
			}
		}
	}
}

# add tailing tags to using global variables
sub addTail() {
	# 1st parameter: name of begin tag
	my $begin = $_[0];
	# 2nd parameter: name of end tag that will be inserted
	my $end = $_[1];
	# 3nd parameter: name of middle tag that will be inserted
	my $middle = $_[2];

	if($statement =~ /^$begin/i) {
		$tagCounter = 0;
		$manyLinesComment = '0';
		# search of END  tag
		for(my $i = $relativeLine - 1; $i < $#functionIndexed; $i++) {
			$functionIndexedLine = $functionIndexed[$i];
			if($functionIndexedLine =~ /(^\d+):\s*--/) {
				# ignore all comments
				next;
			}
			if($functionIndexedLine =~ /(^\d+):\s*\/\*/) {
				# start of many lines comment block 
				$manyLinesComment = '1';
				#next;
			}
			if($functionIndexedLine =~ /\*\/\s*/) {
				# end of many lines comment block
				$manyLinesComment = '0';
				next;
			}
			if ($manyLinesComment == '0') {
				if($functionIndexedLine =~ /(^\d+):\s*$begin/i) {
					$tagCounter++;
				}
				if(length($middle) > 0 
					and $functionIndexedLine =~ /(^\d+):\s*$middle/i) {
					if($tagCounter == 1){
						push(@functionExecutedLines, $1);
					}
				}
				if($functionIndexedLine =~ /(^\d+):\s*$end\s*;/i) {
					$tagCounter--;
					if($tagCounter == 0){
						push(@functionExecutedLines, $1);
						last;
					}
				}
			}
		}
	}
}

# add tailing tags to using global variables
sub addNamedTail() {
	# 1st parameter: name of begin tag
	my $begin = $_[0];
	# 2nd parameter: name of end tag that will be inserted
	my $end = $_[1];
	# 3nd parameter: name of middle tag that will be inserted
	my $middle = $_[2];

	if($statement =~ /(^\w+)\s+:\s+$begin/i) {
		$name = $1;
		$tagCounter = 0;
		$manyLinesComment = '0';
		# search of END  tag
		for(my $i = $relativeLine - 1; $i < $#functionIndexed; $i++) {
			$functionIndexedLine = $functionIndexed[$i];
			if($functionIndexedLine =~ /(^\d+):\s*--/) {
				# ignore all comments
				next;
			}
			if($functionIndexedLine =~ /(^\d+):\s*\/\*/) {
				# start of many lines comment block 
				$manyLinesComment = '1';
				#next;
			}
			if($functionIndexedLine =~ /\*\/\s*/) {
				# end of many lines comment block
				$manyLinesComment = '0';
				next;
			}
			if ($manyLinesComment == '0') {
				if($functionIndexedLine =~ /(^\d+):\s*$name\s*:\s*$begin/i) {
					$tagCounter++;
				}
				if(length($middle) > 0 
					and $functionIndexedLine =~ /(^\d+):\s*$middle/i) {
					if($tagCounter == 1){
						push(@functionExecutedLines, $1);
					}
				}
				if($functionIndexedLine =~ /(^\d+):\s*$end\s+$name\s*;/i) {
					$tagCounter--;
					if($tagCounter == 0){
						push(@functionExecutedLines, $1);
						last;
					}
				}
			}
		}
	}
}

# insert a function indicator for every line that show if a line was exeucted or not
sub calculateAndStoreFunctionIndicator() {
	push(@result, "\nESQL Function / Procedure " . $functionCounter . ": '". $esqlSchemaAndModuleAndFunction . "'\n\n");
	
	$functionExecutableLines = 0;
	$functionNonExecutableLines = 0;
	$functionCommentLines = 0;
	$currentCommandNotFinished = 0;
	$currentCommandNotFinishedAndCase = 0;
	$manyLinesComment = 0;
	
	# the array @functionExecutedLines does not store all executed lines until now, for example:
	# code snipplet:
	#	SELECT C.Rec_2501[]
	#	FROM inTree.Rec_2100_Group[] AS C
	#	WHERE EXISTS(C.Rec_2200_Group[])
	#		AND NOT EXISTS(C.Rec_2300_Group[])
	#		AND NOT EXISTS(C.Rec_2400_Group[]);
	#
	# will result in only one line in usertrace:
	# 2008-03-10 12:30:43.248485     5988   UserTrace   BIP2537I: Node 'IF_029_DMS.Map_DMS': Executing statement   ''SET env.TEMP.calculateTotalTransportCosts[ ] = (SELECT C.Rec_2501[ ] AS :Rec_2501 FROM inTree.Rec_2100_Group[ ] AS C WHERE EXISTS(C.Rec_2200_Group[ ]) AND NOT EXISTS(C.Rec_2300_Group[ ]) AND NOT EXISTS(C.Rec_2400_Group[ ]));'' at ('.calculateTotalTransportCosts', '9.2'). 
	# 
	# therefore this sub calculates the correct count of executed lines
	# @fuctionExecutedLines will be replaced by @newFunctionExecutedLines
	# this is only important to calculate the correct percentage of executed lines - not for displaying the [x] feature	

	@newFunctionExecutedLines = ();	

	foreach my $line (@functionIndexed) 
	{
		$lineAlreadyPrinted = '0';
		# special treatment of many lines comments (/* ... */)
		if ($manyLinesComment) {
			# insert empty space before a line that can't be executed
			push(@result, "    $line");
			$functionCommentLines++;
			if ($line =~ /\*\//) {
				$manyLinesComment = '0';
			}
			# skip the current line
			next;
		}
		# special treatment for many lines statements
		# includes extra special treatment for CASE statements, which are in most cases split in many lines
		if ($currentCommandNotFinished) {
			# if($line =~ /\-\-/ || $line =~ /^\d+:\s+$/ || $line =~ /(^\d+):\s+\/?\*/) 
			if($line =~ /^\d+:\s+\-\-/ || $line =~ /^\d+:\s+$/ || $line =~ /(^\d+):\s+\/\*/) 
			{
				# insert empty space before a line that can't be executed
				push(@result, "    $line");
#$currentCommandNotFinished = '0';
				if($line =~ /^\d+:\s+\-\-/ || $line =~ /(^\d+):\s+\/\*/) 
				{
					$functionCommentLines++;
if($line =~ /(^\d+):\s+\/\*/)
{
$manyLinesComment = '1';
}
				} else {
					$functionNonExecutableLines++;
				}
			} else {
				# insert [x] before a executed line
				push(@result, "[x] $line");
				$lineAlreadyPrinted = '1';
				$functionExecutableLines++;

				# add line to array
				push(@newFunctionExecutedLines, $line);
				
				# remove tailing spaces
				$line =~ s/\s+$//;
				# remove tailing &#xd; charaters
				$line =~ s/\s*\&\#xd\;//;

				#special treatment for CASE command
				if ($line =~ /\sCASE/i) {
					$currentCommandNotFinishedAndCase = '1';
				}
				if ($currentCommandNotFinishedAndCase) {
					# the current command is CASE command - so we only have to search for the ';' character
					if ($line =~ /;$/) {
						$currentCommandNotFinished = '0';
						$currentCommandNotFinishedAndCase = '0';
					}
				} else {
					if ($line =~ /;$/
						or $line =~ /THEN$/i
						or $line =~ /DO$/i
						or $line =~ /BEGIN$/i) {
						$currentCommandNotFinished = '0';
					}
				}
			}
		} else {
			# now the default processing which will match in most cases
			foreach my $linenumber (@functionExecutedLines) 
			{
				if($line =~ /^$linenumber:/) 
				{
					# insert [x] before a executed line
					push(@result, "[x] $line");
					$lineAlreadyPrinted = '1';
					$functionExecutableLines++;

					# add line to array
					push(@newFunctionExecutedLines, $line);

					if (index($line, '--') > 0) {
						$line = substr(($line), 0, index($line, '--'));
						#print "\n$line";
					}
					# remove tailing spaces
					$line =~ s/\s+$//;
					# remove tailing &#xd; charaters
					$line =~ s/\s*\&\#xd\;//;
					if ($line !~ /;$/ 
						&& $line !~ /THEN$/i 
						&& $line !~ /ELSE$/i
						&& $line !~ /BEGIN$/i
						&& $line !~ /DO$/i)
						# && $line !~ /CREATE/)
						# && $line !~ /CALL/) 
					{
						$currentCommandNotFinished = '1';
						# print "\nline = $line";
						# special treatment for CASE statement
						if ($line =~ /\sCASE/i) {
							# the current command could be CASE even if the word CASE is not found here
							$currentCommandNotFinishedAndCase = '1';
						}
					}
					last;
				}
			}
			if($lineAlreadyPrinted == '0') 
			{
				if($line !~ /^\d+:\s+\-\-/          # filter out comments --
					&& $line !~ /^\d+:\s*$/         # filter out empty lines (only whitespaces)					
					&& $line !~ /^\d+:\s*\/\*/      # filter out comments /*
					&& $line !~ /^\d+:\s*\&\#xd\;/) # filter out &#xd;
				{
					# insert [ ] before a not executed line
					push(@result, "[ ] $line");
					$functionExecutableLines++;
				} else {
					# insert empty space before a line that can't be executed
					push(@result, "    $line");
					if($line !~ /^\d+:\s+\-\-/          # filter out comments --
						&& $line !~ /^\d+:\s*\/\*/)      # filter out comments /*
					{
						$functionNonExecutableLines++;
					} else {
						$functionCommentLines++;
					}
					if ($line =~ /^\d+:\s+\/\*/ and $line !~ /\*\//) {
						# if comment /* is not closed on the same line, filter out all following lines
						# until comment close */ is found
						$manyLinesComment = '1';
					}
				}
			}
		}
	}
	
	@functionExecutedLines = @newFunctionExecutedLines;

	# store information for current function or procedure in global hash %esqlModuleAndFunctionHash
	$functionExecutedLines = @functionExecutedLines;
	my @functionStatistics = ($functionExecutedLines, $functionExecutableLines, $functionNonExecutableLines, $functionCommentLines);
	$esqlModuleAndFunctionHash{$esqlSchemaAndModuleAndFunction} = \@functionStatistics;
}

# write report file and calculate code coverage		
sub writeAndCalculateReportFile() {
	open(WRITE,"> $reportFile") or die "Cannot open file: $!\n";

	($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	
	print  WRITE "ESQL Source Code: $esqlFileName\n";
	print  WRITE "User Trace Log  : $logFileName\n";
	printf WRITE "Execution time  : %4d-%02d-%02d %02d:%02d:%02d\n\n", $year+1900,$mon+1,$mday,$hour,$min,$sec;
	printf WRITE "IAM2 version    : 1.0.6\n";

	print WRITE "-------------------------\n";
	print WRITE "Overview of Code Coverage\n";
	print WRITE "-------------------------\n";

	$totalNodes = @esqlModules;
	# print WRITE "Total ESQL Modules          : $totalNodes\n";
	$totalFunctions = $functionCounter;
	print WRITE "Total Functions & Procedures: $totalFunctions\n\n";

	# extract information for every function or procedure from global hash %esqlModuleAndFunctionHash
	foreach my $function (sort keys %esqlModuleAndFunctionHash) {
		$executedLines = $esqlModuleAndFunctionHash{$function}[0];
		$executableLines = $esqlModuleAndFunctionHash{$function}[1];
		$nonExecutableLines = $esqlModuleAndFunctionHash{$function}[2]; # actual all blank lines
		$commentLines = $esqlModuleAndFunctionHash{$function}[3];
		$totalLines = $executableLines + $nonExecutableLines + $commentLines;

		if ($executableLines > 0) {		
			$codeCoverage = sprintf("%5.1f", $executedLines / $executableLines * 100);
			$percentComment = sprintf("%5.1f", $commentLines / ($executableLines + $commentLines) * 100);
		} else {
			$codeCoverate = sprintf("%5.1f", 0);
			$percentComment = sprintf("%5.1f", 0);
		}
		print WRITE "'$function'\n";
		print WRITE "Lines           : $totalLines ($commentLines comment and $nonExecutableLines blank lines)\n";
		print WRITE "Executed Lines  : $executedLines of $executableLines executable lines\n";
		print WRITE "Percent comment : $percentComment%\n";
		print WRITE "Code coverage   : $codeCoverage%\n\n";	 
		$totalExecutedLines += $executedLines;
		$totalExecutableLines += $executableLines;
	}

	$totalExecutedCodePercentage = sprintf("%.1f", $totalExecutedLines /  $totalExecutableLines * 100);
	$totalMissingCodePercentage = 100 - $totalExecutedCodePercentage;

	print WRITE "Total Executed Lines : $totalExecutedLines of $totalExecutableLines executable lines\n";
	print WRITE "Total Code Coverage  : $totalExecutedCodePercentage%\n\n";

	print WRITE "------------------------\n";
	print WRITE "Details of Code Coverage\n";
	print WRITE "------------------------\n";

	print WRITE "[x] line was executed\n";
	print WRITE "[ ] line was not executed\n";
	print WRITE "    line is comment or blank line\n";

	print WRITE @result;
	close(WRITE);
}