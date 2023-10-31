Updates:

v1.0.6
- fix for issue with spaces between 'END <xyz>' and ';'
- fix for multi line comment blocks outside of functions or procedures

v1.0.5
- tested with IIB v10
- tested on Ubuntu 14.04 LTS

v1.0.4
- tested with WMB v8
- tested on Windows 7 Prof
- added non-en_US version (to handle non-english trace files)

v1.0.3
- fix to correctly handle external java procedures
- tested with WMB v7
- fix to correctly identify keywords like END

v1.0.2
- fix to correctly handle schema names with dots in the name (like 'com.ibm.wbi.schema')
- fix to correctly handle functions with the same name in different schemas

v1.0.1
- fix for empty lines with &xd; encoding
- fix for standalone functions (outside of modules)
- fix to correctly recognize the end of functions / procedures
- fix to ignore case of keywords like IF, THEN, DO...
- fix to correctly recognize the WHEN keyword in CASE statements
- fix to correctly handle schema names with dots in the name (like 'com.ibm.wbi.schema')


This perl script "evaluator.pl" is a code coverage tool for ESQL code.
It can be used for unit testing after test messages have been sent to test an interface
in order to create a report whether parts of ESQL code were executed or not.

How it works:
-------------
This perl script needs a tracelog file of a user trace in debug mode and the source code file.
It compares the information of both files to create a report where every single code line is marked
as executed, not executed or not relevant (e.g. blank lines and comments).

The report shows statistics for every single procedure and function of the ESQL source code and
finally a total code coverage indicator for the whole ESQL file.

Files:
------
evaluator.pl    : Perl script that creates a report about code coverage.
tracelog.pattern: The regex pattern of the trace log file.

Prerequisites:
--------------

1.
You need to have a perl interpreter installed. For Windows is a free distribution available from
ActiveState at: http://www.activestate.com/Products/activeperl. Set the Path variable to the bin
directory of your Perl installation e.g.

C:\Perl\bin

2.
Create a BAR file with the required message flow and deploy it. Make a copy and rename to *.zip,
open the ZIP file and extract the CMF file for the required flow which will server as the source code file.
Copy the CMF file of the interface you want to test to the directory that contains the
files "evaluator.pl" and "tracelog.pattern".

3.
Set user trace to debug mode for the Flow you want to test either from command line 
(mqsichangetrace  <broker_name> -u -e <eg_name> -f <flow_name> -l debug -c 20000 -r)
or via Message Broker Toolkit 
(Broker Administration perspective --> Domains View --> right click on deployed flow in
execution group --> User Trace --> Debug).

4.
Send as many test messages you want to test the interface but at least one.

5.
Retrieve the user trace file from command line:
mqsireadlog  <broker_name> -u -e <eg_name> -o usertrace.xml
mqsiformatlog -i usertrace.xml -o usertrace.txt
Optional: disable user trace:
mqsichangetrace <broker_name> -u -e <eg_name> -f <flow_name> -l none -c 20000 -r

7.
Copy the user trace log file to the directory that contains the files "evaluator.pl" and
"tracelog.pattern".

Usage:
------
perl evaluator.pl <tracelogFile> <cmffile> <reportFile>

The perl script will create a report file with the specified name.

As the script can currently only support one source code file it is recommended to take
the CMF file from the BAR file instead of the ESQL file, because the CMF file will
also contain referenced functions or procedures which are not containend in the ESQL
source file.

Limitations:
------------
For the moment only ESQL source code is supported.
The following mapping techniques are not supported: 
- JavaCompute node
- XSLT
- Graphical mapping node

Author:
-------
Matthias Kabala
Torsten Schaefer
torsten.schaefer@de.ibm.com
