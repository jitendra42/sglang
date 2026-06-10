#!/usr/bin/env bash

set -euo pipefail

venv_dir="${1:?venv dir required}"
python_version="${2:?python version required}"

lib_dir="${venv_dir}/lib"
site_packages="${lib_dir}/python${python_version}/site-packages"

strip_if_exists() {
    local file
    for file in "$@"; do
        if [[ -f "${file}" ]]; then
            strip --strip-unneeded "${file}"
        fi
    done
}

strip_if_exists \
    "${site_packages}/triton/_C/libtriton.so" \
    "${site_packages}/triton/_C/libproton.so" \
    "${site_packages}/triton/plugins/libMLIRDialectPlugin.so.23.0git" \
    "${site_packages}/torch/lib/libtorch_cpu.so" \
    "${site_packages}/torch/lib/libtorch_python.so" \
    "${site_packages}/torch/lib/libtorch_xpu.so"

# Strip every remaining shared object in the venv. The torch/triton libraries
# above are already covered; this pass also catches the third-party extension
# modules (pyarrow, scipy, tokenizers, Cryptodome, ...) that ship with debug
# symbols, reclaiming ~150MB+ without enumerating each package by hand. It is
# self-maintaining as dependencies change.
while IFS= read -r -d '' file; do
    strip --strip-unneeded "${file}" || true
done < <(find "${lib_dir}" -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' \) -print0)

while IFS= read -r -d '' file; do
    strip --strip-unneeded "${file}" || true
done < <(find "${site_packages}" -type f \( -name '*.so' -o -name '*.so.*' \) -print0)

rm -f "${lib_dir}/libiomp5.dbg"

tmp_dir="$(mktemp -d)"
manifest="${tmp_dir}/manifest.tsv"
links="${tmp_dir}/links.tsv"

while IFS= read -r -d '' file; do
    checksum="$(sha256sum "${file}" | cut -d' ' -f1)"
    size="$(stat -c '%s' "${file}")"
    base_name="$(basename "${file}")"
    printf '%s\t%s\t%s\n' "${checksum}" "${size}" "${base_name}" >> "${manifest}"
done < <(find "${lib_dir}" -maxdepth 1 -type f -print0)

sort "${manifest}" | awk -F '\t' '
{
    count[$1]++
    rows[$1] = rows[$1] ORS $2 "\t" $3
}
END {
    for (checksum in count) {
        if (count[checksum] < 2) {
            continue
        }

        split(rows[checksum], entries, ORS)
        target = ""
        target_len = -1

        for (i in entries) {
            if (entries[i] == "") {
                continue
            }
            split(entries[i], parts, "\t")
            name = parts[2]
            if (length(name) > target_len || (length(name) == target_len && name > target)) {
                target = name
                target_len = length(name)
            }
        }

        for (i in entries) {
            if (entries[i] == "") {
                continue
            }
            split(entries[i], parts, "\t")
            name = parts[2]
            if (name != target) {
                printf "%s\t%s\n", target, name
            }
        }
    }
}' > "${links}"

while IFS=$'\t' read -r target name; do
    rm -f "${lib_dir}/${name}"
    ln -s "${target}" "${lib_dir}/${name}"
done < "${links}"

rm -rf "${tmp_dir}"
