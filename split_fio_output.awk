# Split fio's combined normal,json+ stream without assuming which format comes
# first. The first complete top-level JSON object is written to json_file;
# everything before and after it is preserved in normal_file.

BEGIN {
    state = 0
    depth = 0
    in_string = 0
    escaped = 0
    started = 0
    complete = 0
    printf "" > normal_file
    printf "" > json_file
}

function write_normal(text) {
    print text >> normal_file
}

function write_json(text) {
    print text >> json_file
}

{
    line = $0

    if (state == 0) {
        if (match(line, /^[[:space:]]*\{/)) {
            prefix = substr(line, 1, RSTART - 1)
            if (prefix ~ /[^[:space:]]/)
                write_normal(prefix)
            line = substr(line, RSTART)
            state = 1
            started = 1
        } else {
            write_normal(line)
            next
        }
    } else if (state == 2) {
        write_normal(line)
        next
    }

    end_position = 0
    for (i = 1; i <= length(line); i++) {
        character = substr(line, i, 1)
        if (in_string) {
            if (escaped) {
                escaped = 0
            } else if (character == "\\") {
                escaped = 1
            } else if (character == "\"") {
                in_string = 0
            }
        } else if (character == "\"") {
            in_string = 1
        } else if (character == "{") {
            depth++
        } else if (character == "}") {
            depth--
            if (depth == 0) {
                end_position = i
                complete = 1
                state = 2
                break
            }
        }
    }

    if (end_position > 0) {
        write_json(substr(line, 1, end_position))
        suffix = substr(line, end_position + 1)
        if (suffix != "")
            write_normal(suffix)
    } else {
        write_json(line)
    }
}

END {
    close(normal_file)
    close(json_file)
    if (!started)
        exit 42
    if (!complete)
        exit 43
}
