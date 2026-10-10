#!/bin/zsh
task_dir="${0:A:h}"
task_venv="$HOME/Library/Caches/ReadingHubWeread/venv"
if [[ ! -x "$task_venv/bin/python" ]]; then
  python3 -m venv "$task_venv"
fi
if ! "$task_venv/bin/python" -c 'import pyppeteer' >/dev/null 2>&1; then
  "$task_venv/bin/python" -m pip install 'pyppeteer==2.0.0'
fi
"$task_venv/bin/python" "$task_dir/weread_export.py" "$@"
task_result=$?
read '?按回车关闭窗口。'
exit "$task_result"
