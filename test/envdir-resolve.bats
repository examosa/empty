#!/usr/bin/env bats
# Tests for the envdir-resolve script.

ENVDIR_RESOLVE="${BATS_TEST_DIRNAME}/../envdir-resolve"

setup() {
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
    export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
    src_dir="$XDG_CONFIG_HOME/env"
    dst_dir="$XDG_STATE_HOME/env"
    mkdir -p "$src_dir"

    # Stub envdir: just exits 0 so we can inspect $dst_dir afterwards.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/envdir"
    chmod +x "$BATS_TEST_TMPDIR/bin/envdir"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

@test "exits with usage when no PROG is given" {
    run "$ENVDIR_RESOLVE" --
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "exits with error on an unknown option" {
    run "$ENVDIR_RESOLVE" --unknown -- true
    [ "$status" -eq 1 ]
}

@test "exits with error when multiple positional args appear before --" {
    run "$ENVDIR_RESOLVE" /one /two -- true
    [ "$status" -eq 1 ]
}

@test "exits with error when src_dir does not exist" {
    run "$ENVDIR_RESOLVE" /nonexistent-path-xyz -- true
    [ "$status" -eq 1 ]
}

@test "accepts a custom source directory via positional argument" {
    custom_src="$BATS_TEST_TMPDIR/custom-src"
    mkdir -p "$custom_src"
    printf 'hello\n' > "$custom_src/MYVAR"

    run "$ENVDIR_RESOLVE" "$custom_src" -- true
    [ "$status" -eq 0 ]
    [ "$(cat "$dst_dir/MYVAR")" = "hello" ]
}

# ---------------------------------------------------------------------------
# Basic expansion
# ---------------------------------------------------------------------------

@test "resolves a \$VAR reference" {
    printf 'world\n' > "$src_dir/B"
    printf '$B\n'    > "$src_dir/A"
    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ "$(cat "$dst_dir/A")" = "world" ]
}

@test "resolves a \${VAR} reference" {
    printf 'world\n'  > "$src_dir/B"
    printf '${B}\n'   > "$src_dir/A"
    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ "$(cat "$dst_dir/A")" = "world" ]
}

@test "resolves multiple references in a single value" {
    printf 'foo\n'   > "$src_dir/X"
    printf 'bar\n'   > "$src_dir/Y"
    printf '$X-$Y\n' > "$src_dir/Z"
    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ "$(cat "$dst_dir/Z")" = "foo-bar" ]
}

@test "preserves literal text surrounding references" {
    printf 'world\n'       > "$src_dir/NAME"
    printf 'hello $NAME!\n' > "$src_dir/MSG"
    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ "$(cat "$dst_dir/MSG")" = "hello world!" ]
}

@test "resolves nested references transitively" {
    printf 'hello\n' > "$src_dir/C"
    printf '$C\n'    > "$src_dir/B"
    printf '$B\n'    > "$src_dir/A"
    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ "$(cat "$dst_dir/A")" = "hello" ]
}

@test "falls back to the calling environment for variables not in src_dir" {
    printf '$MY_ENVDIR_TEST_VAR\n' > "$src_dir/A"
    run env MY_ENVDIR_TEST_VAR=fromenv "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ "$(cat "$dst_dir/A")" = "fromenv" ]
}

@test "expands to empty string when variable is absent from src_dir and environment" {
    printf '$UNSET_ENVDIR_VAR_XYZ\n' > "$src_dir/A"
    run env -u UNSET_ENVDIR_VAR_XYZ "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ "$(cat "$dst_dir/A")" = "" ]
}

@test "detects cyclic references and exits with error" {
    printf '$B\n' > "$src_dir/A"
    printf '$A\n' > "$src_dir/B"
    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 1 ]
    [[ "$output" == *"cycle"* ]]
}

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

@test "strips trailing whitespace from values" {
    printf 'hello   \n' > "$src_dir/A"
    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ "$(cat "$dst_dir/A")" = "hello" ]
}

@test "preserves leading whitespace in values" {
    printf '  hello\n' > "$src_dir/A"
    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ "$(cat "$dst_dir/A")" = "  hello" ]
}

@test "treats an all-whitespace value as empty" {
    printf '   \n' > "$src_dir/A"
    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ "$(cat "$dst_dir/A")" = "" ]
}

@test "reads only the first line of each file" {
    printf 'first\nsecond\n' > "$src_dir/A"
    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ "$(cat "$dst_dir/A")" = "first" ]
}

# ---------------------------------------------------------------------------
# File filtering
# ---------------------------------------------------------------------------

@test "skips dot-files in src_dir" {
    printf 'hidden\n' > "$src_dir/.hidden"
    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ ! -f "$dst_dir/.hidden" ]
}

@test "skips files whose name contains '='" {
    printf 'value\n' > "$src_dir/KEY=BAD"
    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ ! -f "$dst_dir/KEY=BAD" ]
}

# ---------------------------------------------------------------------------
# Up-to-date check
# ---------------------------------------------------------------------------

@test "skips regeneration when dst_dir is newer than all src files" {
    # Pre-populate dst_dir with a sentinel value
    mkdir -p "$dst_dir"
    printf 'cached\n' > "$dst_dir/A"

    # Create src file but age it well into the past
    printf 'new_value\n' > "$src_dir/A"
    touch -d '1970-01-01' "$src_dir/A"

    # Make dst_dir's mtime current (newer than the src file)
    touch "$dst_dir"

    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    # dst_dir was not regenerated — sentinel value must still be present
    [ "$(cat "$dst_dir/A")" = "cached" ]
}

@test "regenerates when a src file is newer than dst_dir" {
    # Pre-populate dst_dir with an old value and age the directory
    mkdir -p "$dst_dir"
    printf 'old_value\n' > "$dst_dir/A"
    touch -d '1970-01-01' "$dst_dir"

    # Create src file with current mtime (newer than the aged dst_dir)
    printf 'new_value\n' > "$src_dir/A"

    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ "$(cat "$dst_dir/A")" = "new_value" ]
}

# ---------------------------------------------------------------------------
# Stale file removal
# ---------------------------------------------------------------------------

@test "removes files from dst_dir that no longer exist in src_dir" {
    # Pre-populate dst_dir with a file that has no counterpart in src
    mkdir -p "$dst_dir"
    printf 'stale\n' > "$dst_dir/STALE"
    touch -d '1970-01-01' "$dst_dir"

    # src has a different file, so regeneration is triggered
    printf 'current\n' > "$src_dir/CURRENT"

    run "$ENVDIR_RESOLVE" -- true
    [ "$status" -eq 0 ]
    [ ! -f "$dst_dir/STALE" ]
    [ -f "$dst_dir/CURRENT" ]
}
