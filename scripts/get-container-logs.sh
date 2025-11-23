#!/bin/bash
set -e

echo "**** stderr.log ****\n"
cat /Users/kiener/Library/Application\ Support/com.apple.arca/logs/$1/stderr.log
echo "\n\n\n**** stdout.log ****\n"
cat /Users/kiener/Library/Application\ Support/com.apple.arca/logs/$1/stdout.log
