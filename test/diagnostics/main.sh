#!/bin/bash
actual=$(../../bin/crow check crow-config.json --no-color --all-errors 2>&1)
expected=$(<expected.txt)
if [ "$actual" = "$expected" ]; then
	# TODO: is this line actually needed? -------------------------------------------------------------------------------------------
	exit 0
else
	diff <(echo "$foo_output") <(echo "$expected_output")
	exit 1
fi
