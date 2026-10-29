#!/bin/bash
# Build or test with compact output: only errors, warnings from our sources, and the summary.
#   ./build.sh           build everything
#   ./build.sh test      run the tests
#   ./build.sh test Name run tests matching a filter
cd "$(dirname "$0")"
if [ "${1:-build}" = "test" ]; then
  swift test ${2:+--filter "$2"} 2>&1 | grep -E "error:|warning: .*(Sources|Tests)/(WinPhone|winphone)|Test Suite 'All tests'|Executed [0-9]+ tests|failed|XCTAssert|: error|Build complete|error: Build failed" | grep -v "Generated/" | sed -E 's/\x1b\[[0-9;]*m//g' | cut -c1-400 | tail -${LINES_MAX:-40}
else
  swift build 2>&1 | grep -E "error|warning: .*Sources/(WinPhone|winphone)|Build complete|Compiling|Build failed" | grep -vE "Generated/|^\[|Failed frontend" | sed -E 's/\x1b\[[0-9;]*m//g' | cut -c1-400 | tail -${LINES_MAX:-40}
fi
