#!/usr/bin/env bash
# Запуск тестов: tests/run.sh [-j N] [файлы или каталоги...]
# Каждый файл *_spec.lua идёт в отдельном процессе nvim без пользовательской конфигурации.
# Внешний предел всего прогона — CLAUDR_TEST_LIMIT (секунды, по умолчанию 600).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"

if [ -z "${CLAUDR_RUN_INNER:-}" ]; then
  export CLAUDR_RUN_INNER=1
  exec timeout "${CLAUDR_TEST_LIMIT:-600}" "$0" "$@"
fi

jobs=8
if [ "${1:-}" = "-j" ]; then
  jobs="$2"
  shift 2
fi

cd "$root" || exit 2
[ "$#" -eq 0 ] && set -- tests

files=()
for arg in "$@"; do
  if [ -d "$arg" ]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$arg" -name '*_spec.lua' | sort)
  else
    files+=("$arg")
  fi
done
if [ "${#files[@]}" -eq 0 ]; then
  echo "нет файлов тестов" >&2
  exit 2
fi

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

run_one() {
  local idx="$1" file="$2"
  nvim --headless --clean -u NONE -l tests/bootstrap.lua "$file" >"$out/$idx.log" 2>&1
  echo $? >"$out/$idx.rc"
}

# Параллельный запуск: не больше $jobs процессов одновременно, ожидание — по выходу процесса.
running=0
for i in "${!files[@]}"; do
  if [ "$running" -ge "$jobs" ]; then
    wait -n
    running=$((running - 1))
  fi
  run_one "$i" "${files[$i]}" &
  running=$((running + 1))
done
wait

pass_files=0
fail_files=0
sum_pass=0
sum_fail=0
printf '%-8s %-8s %s\n' "ИТОГ" "ТЕСТЫ" "ФАЙЛ"
for i in "${!files[@]}"; do
  rc="$(cat "$out/$i.rc" 2>/dev/null || echo 1)"
  line="$(grep -a '^ИТОГ прошло=' "$out/$i.log" | tail -n 1)"
  p="$(sed -n 's/.*прошло=\([0-9]*\).*/\1/p' <<<"$line")"
  f="$(sed -n 's/.*упало=\([0-9]*\).*/\1/p' <<<"$line")"
  p="${p:-0}"
  f="${f:-0}"
  sum_pass=$((sum_pass + p))
  sum_fail=$((sum_fail + f))
  if [ "$rc" -eq 0 ]; then
    pass_files=$((pass_files + 1))
    printf '%-8s %-8s %s\n' "ok" "$p" "${files[$i]}"
  else
    fail_files=$((fail_files + 1))
    printf '%-8s %-8s %s\n' "FAIL" "$p/$f" "${files[$i]}"
    sed 's/^/    | /' "$out/$i.log"
  fi
done
echo "файлов: прошло $pass_files, упало $fail_files; тестов: прошло $sum_pass, упало $sum_fail"
[ "$fail_files" -eq 0 ]
