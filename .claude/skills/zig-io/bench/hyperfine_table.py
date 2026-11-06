"""hyperfine_table.py <run.json> [<label>...]: a Markdown table of a hyperfine JSON export:
median wall time, median user and system CPU time, peak resident memory and
retired instructions where hyperfine records them (2.0's schema; 1.x gives
times only), and each command's wall time against the first command's (the
zffmpeg row). The labels name the commands in order (hyperfine 2.0's
export keeps the command line, not `-n`)."""
import json
import statistics
import sys


def row(result):
    """(wall, user, system, peak bytes or None, instructions or None)."""
    if "summary" in result:  # hyperfine 2.0
        s = result["summary"]

        def median(key):
            return s[key]["median"] if key in s and s[key].get("count") else None

        return (median("time_wall_clock"), median("time_user"), median("time_system"),
                median("memory_peak_resident"), median("instructions"))
    return statistics.median(result["times"]), result["user"], result["system"], None, None


labels = sys.argv[2:]
results = [(labels[i] if i < len(labels) else r["command"], row(r))
           for i, r in enumerate(json.load(open(sys.argv[1]))["results"])]
base = results[0][1][0]
print("| Command | Wall (median) | User | System | CPU (user + system) | Peak RSS | Instructions | zffmpeg wall / this wall |")
print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
for command, (wall, user, system, peak, instructions) in results:
    peak_text = f"{peak / 1048576:.0f} MiB" if peak is not None else "-"
    instructions_text = f"{instructions / 1e9:.2f} G" if instructions is not None else "-"
    print(f"| {command} | {wall:.3f} s | {user:.3f} s | {system:.3f} s | {user + system:.3f} s | {peak_text} | "
          f"{instructions_text} | {base / wall:.2f}x |")
