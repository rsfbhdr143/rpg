@echo off
rem Импорт картинок из art\inbox в игру. Нужен Python 3.9+ (python.org, при установке отметь "Add python.exe to PATH").
chcp 65001 >nul
cd /d "%~dp0..\.."
set "PY=python"
where py >nul 2>nul && set "PY=py -3"
%PY% -m pip install --quiet --disable-pip-version-check pillow numpy
%PY% tools\art\import_art.py %*
echo.
echo Проверь картинки: art\review\overview.png и art\review\bindings.png
pause
