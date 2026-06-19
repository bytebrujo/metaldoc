#!/bin/sh
# Phase 0 MSL spike: confirm the parsing mechanism for the Metal Shading Language.
#
# Finding: the Metal toolchain ships NO libclang (no libclang.dylib, no clang-c/
# headers), so MSL cannot reuse the metal-cpp libclang path. We must shell out to
# the toolchain's own `metal` driver, which speaks the Metal dialect.
set -e
here="$(cd "$(dirname "$0")" && pwd)"

echo "== libclang in Metal toolchain? =="
tc="$(dirname "$(xcrun -f metal)")/.."
find "$tc" -name 'libclang*' -o -name 'clang-c' 2>/dev/null | head || true
echo "(empty => none; must shell out to xcrun metal)"
echo

echo "== compile + JSON AST dump of a kernel =="
xcrun metal -x metal -std=metal3.2 -fsyntax-only \
  -Xclang -ast-dump=json "$here/probe_kernel.metal" \
  > "$here/kernel_ast.json" 2>/dev/null
echo "kernel_ast.json bytes: $(wc -c < "$here/kernel_ast.json")"
grep -o '"name": "add_arrays"' "$here/kernel_ast.json" | head -1
grep -o 'MetalKernelAttr' "$here/kernel_ast.json" | head -1
echo

echo "== enumerate a stdlib overload set (metal::dot) =="
printf '#include <metal_stdlib>\nusing namespace metal;\n' > "$here/stdlib_only.metal"
xcrun metal -x metal -std=metal3.2 -fsyntax-only \
  -Xclang -ast-dump=json -Xclang -ast-dump-filter=dot \
  "$here/stdlib_only.metal" > "$here/dot_ast.json" 2>/dev/null
echo "dot FunctionDecl nodes: $(grep -c '"kind": "FunctionDecl"' "$here/dot_ast.json")"
