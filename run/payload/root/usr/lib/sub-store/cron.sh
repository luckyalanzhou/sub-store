#!/bin/sh

sub_store_valid_cron() {
    printf '%s\n' "$1" | awk '
        function valid_field(field, minimum, maximum, items, count, i, parts, part_count, base, step, ranges, range_count, low, high, number) {
            if (field == "" || field ~ /(^,|,$|,,)/) return 0
            count = split(field, items, ",")
            for (i = 1; i <= count; i++) {
                part_count = split(items[i], parts, "/")
                if (part_count > 2) return 0
                base = parts[1]
                if (part_count == 2) {
                    step = parts[2]
                    if (step !~ /^[0-9]+$/ || step + 0 < 1) return 0
                }
                if (base == "*") continue
                range_count = split(base, ranges, "-")
                if (range_count == 1) {
                    if (base !~ /^[0-9]+$/) return 0
                    number = base + 0
                    if (number < minimum || number > maximum) return 0
                } else if (range_count == 2) {
                    if (ranges[1] !~ /^[0-9]+$/ || ranges[2] !~ /^[0-9]+$/) return 0
                    low = ranges[1] + 0
                    high = ranges[2] + 0
                    if (low < minimum || high > maximum || low > high) return 0
                } else {
                    return 0
                }
            }
            return 1
        }
        NF != 5 { exit 1 }
        !valid_field($1, 0, 59) || !valid_field($2, 0, 23) || !valid_field($3, 1, 31) ||
        !valid_field($4, 1, 12) || !valid_field($5, 0, 7) { exit 1 }
        { exit 0 }
    '
}
