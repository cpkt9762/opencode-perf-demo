#!/bin/bash
# Generates a large git repo that reproduces opencode perf issues.
#
# Usage:
#   bash create-demo.sh [small|medium|large]
#     small  = 50k files   (~400MB, mild CPU spike)
#     medium = 200k files  (~1.5GB, noticeable CPU spike)  [default]
#     large  = 500k files  (~4GB, sustained 100-200% CPU)
#
# After running:
#   opencode          # TUI: observe CPU via Activity Monitor / htop
#   opencode serve    # headless: observe with `ps aux | grep opencode`
set -euo pipefail

SCALE="${1:-medium}"
case "$SCALE" in
  small)  DIRS=500;  DESC="50k files"  ;;
  medium) DIRS=2000; DESC="200k files" ;;
  large)  DIRS=5000; DESC="500k files" ;;
  *) echo "Usage: $0 [small|medium|large]"; exit 1 ;;
esac

FILES_PER_DIR=100
TOTAL=$((DIRS * FILES_PER_DIR))

echo "=== Generating $DESC ($SCALE) ==="

if [ -d "src/module-000" ]; then
  echo "Files already exist. Delete src/ vendor/ tmp-generated/ to regenerate."
  exit 1
fi

echo "[1/6] Generating $TOTAL files across $DIRS directories..."
for i in $(seq -w 0 $((DIRS - 1))); do
  dir="src/mod-$i"
  mkdir -p "$dir"
  for j in $(seq -w 0 $((FILES_PER_DIR - 1))); do
    echo "// mod-$i/f-$j.ts" > "$dir/f-$j.ts"
  done
  # progress
  if [ $((10#$i % 500)) -eq 0 ] && [ "$i" != "000" ]; then
    echo "  ... $i / $DIRS dirs"
  fi
done

echo "[2/6] Creating 5 large files (1MB each, 20k lines)..."
mkdir -p src/large
for i in $(seq 1 5); do
  python3 -c "
for n in range(20000):
    print(f'export const v{n} = {n} // big-$i ln {n}')
" > "src/large/big-$i.ts"
done

echo "[3/6] Committing all files (this is slow on large scale)..."
git add -A
git commit -m "initial: $DESC + 5 large files" --no-gpg-sign -q

echo "[4/6] Dirtying 500 files..."
for i in $(seq -w 0 499); do
  dir_idx=$((10#$i / FILES_PER_DIR))
  file_idx=$((10#$i % FILES_PER_DIR))
  dir=$(printf "src/mod-%04d" $dir_idx)
  file=$(printf "f-%02d.ts" $file_idx)
  [ -f "$dir/$file" ] && echo "// DIRTY" >> "$dir/$file"
done

echo "[5/6] Creating nested git repos (broken submodule simulation)..."
mkdir -p vendor/nested-a
(cd vendor/nested-a && git init -b main -q && git config user.name t && git config user.email t@t && echo x > f.txt && git add -A && git commit -m init --no-gpg-sign -q) 2>/dev/null

mkdir -p vendor/broken/.git/objects vendor/broken/.git/refs
echo "ref: refs/heads/nonexistent" > vendor/broken/.git/HEAD

echo "[6/6] Creating 1000 untracked files..."
mkdir -p gen
for i in $(seq 1 1000); do echo "$i" > "gen/$i.txt"; done

TRACKED=$(git ls-files | wc -l | tr -d ' ')
DIRTY=$(git status --porcelain 2>/dev/null | grep -c '^ M' || echo 0)
SIZE=$(du -sh . 2>/dev/null | cut -f1)

echo ""
echo "=== Done ==="
echo "  $TRACKED tracked, $DIRTY dirty, 1000 untracked, $SIZE on disk"
echo ""
echo "Reproduce:"
echo "  opencode        # watch CPU in Activity Monitor"
echo "  # or"
echo "  opencode serve --port 19876 &"
echo "  sleep 10"
echo "  # modify files to trigger watcher:"
echo '  for f in src/mod-000{0..9}/f-0{0..9}.ts; do echo "// poke" >> "$f"; done'
echo "  ps aux | grep opencode   # check %CPU"
