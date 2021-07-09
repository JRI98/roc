#!/usr/bin/env bash

# script to return exit code 1 if benchmarks have regressed

# benchmark trunk
ulimit -s unlimited
cd bench-folder-trunk
./target/release/deps/time_bench --bench
cd ..

# move benchmark results so they can be compared later
cp -r bench-folder-trunk/target/criterion bench-folder-branch/target/

cd bench-folder-branch

LOG_FILE="bench_log.txt"
touch $LOG_FILE

FULL_CMD=" ./target/release/deps/time_bench --bench"
echo $FULL_CMD

script -efq $LOG_FILE -c "$FULL_CMD"
EXIT_CODE=$?
    
if grep -q "regressed" "$LOG_FILE"; then
    echo ""
    echo ""
    echo "------<<<<<<>>>>>>------"
    echo "Benchmark detected regression. Running benchmark again to confirm..."
    echo "------<<<<<<>>>>>>------"
    echo ""
    echo ""

    # delete criterion folder to compare to trunk only
    rm -rf ./target/criterion
    # copy benchmark data from trunk again
    cp -r ../bench-folder-trunk/target/criterion ./target

    rm $LOG_FILE
    touch $LOG_FILE

    script -efq $LOG_FILE -c "$FULL_CMD"
    EXIT_CODE=$?

    if grep -q "regressed" "$LOG_FILE"; then
        echo ""
        echo ""
        echo "------<<<<<<!!!!!!>>>>>>------"
        echo "Benchmarks were run twice and a regression was detected both times."
        echo "------<<<<<<!!!!!!>>>>>>------"
        echo ""
        echo ""
        exit 1
    else
        echo "Benchmarks were run twice and a regression was detected on one run. We assume this was a fluke."
        exit 0
    fi
else
    echo ""
    echo ""
    echo "------<<<<<<!!!!!!>>>>>>------"
    echo "Benchmark execution failed with exit code: $EXIT_CODE."
    echo "------<<<<<<!!!!!!>>>>>>------"
    echo ""
    echo ""
    exit $EXIT_CODE
fi