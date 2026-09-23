@echo off
rem Build tessera into bin\. Needs odin on PATH and the MSVC linker (run from a
rem "x64 Native Tools" prompt).
cd /d "%~dp0"
if not exist bin mkdir bin
odin build src -out:bin\tessera.exe -o:speed -vet -strict-style %*
if errorlevel 1 exit /b 1
