"""Takes the home screen widget out of project.yml (for a build whose App IDs aren't set up for it yet).
Removes every line ending in '# widget' and everything between '# widget-start' and '# widget-end'."""
import sys
path = sys.argv[1] if len(sys.argv) > 1 else "project.yml"
out, skipping = [], False
for line in open(path):
    s = line.strip()
    if s == "# widget-start":
        skipping = True
        continue
    if s == "# widget-end":
        skipping = False
        continue
    if skipping or s.endswith("# widget"):
        continue
    out.append(line)
open(path, "w").write("".join(out))
print("widget removed from", path)
