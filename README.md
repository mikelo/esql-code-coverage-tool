# esql-code-coverage-tool

This repository is used to hold the source code and instructions for configuring the IBM App Connect Enterprise ESQL Code Coverage Tool. Previously this capability was provided as IBM Support Pac IAM2.

# New version has been ported to python

Please enable service trace from the toolkit:
![alt text](image.png)

Use integration_server.[server_name].trace.0.txt as log file to be processed

For example:

evaluator.py integration_server.[server_name].trace.0.txt file.esql report.txt