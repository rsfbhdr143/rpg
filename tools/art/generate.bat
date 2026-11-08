@echo off
rem Картинки из Stable Diffusion (ComfyUI). Без параметров рисует всё, чего ещё нет, по 3 варианта.
rem   generate.bat units/knight          только рыцарь
rem   generate.bat --more units/knight   ещё варианты
rem   generate.bat --pick units/knight=2 выбрать вариант 2, потом запусти import_art.bat
rem Что рисовать — tools\art\prompts.json. Сравнить варианты — art\generated\<категория>.png.
chcp 65001 >nul
cd /d "%~dp0..\.."
rem Python: лаунчер py, иначе Python из Comfy Desktop, иначе python из PATH
set "PY=python"
set "PYARG="
set "COMFY_PY=%LOCALAPPDATA%\Comfy-Desktop\ComfyUI-Installs\ComfyUI\ComfyUI\.venv\Scripts\python.exe"
if exist "%COMFY_PY%" set "PY=%COMFY_PY%"
where py >nul 2>nul && (set "PY=py" & set "PYARG=-3")
"%PY%" %PYARG% -c "import numpy, PIL" 2>nul || "%PY%" %PYARG% -m pip install --quiet --disable-pip-version-check pillow numpy
"%PY%" %PYARG% tools\art\generate.py %*
echo.
pause
