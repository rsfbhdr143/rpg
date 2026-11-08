@echo off
rem Импорт картинок из art\inbox в игру. Нужен Python 3.9+ (python.org, при установке отметь "Add python.exe to PATH")
rem или установленный Comfy Desktop (у него свой Python).
chcp 65001 >nul
cd /d "%~dp0..\.."
rem Python: лаунчер py, иначе Python из Comfy Desktop, иначе python из PATH
set "PY=python"
set "PYARG="
set "COMFY_PY=%LOCALAPPDATA%\Comfy-Desktop\ComfyUI-Installs\ComfyUI\ComfyUI\.venv\Scripts\python.exe"
if exist "%COMFY_PY%" set "PY=%COMFY_PY%"
where py >nul 2>nul && (set "PY=py" & set "PYARG=-3")
"%PY%" %PYARG% -c "import numpy, PIL" 2>nul || "%PY%" %PYARG% -m pip install --quiet --disable-pip-version-check pillow numpy
"%PY%" %PYARG% tools\art\import_art.py %*
echo.
echo Проверь картинки: art\review\overview.png и art\review\bindings.png
pause
