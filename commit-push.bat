@echo off
setlocal
cd /d "%~dp0"

if not exist ".git" (
    echo Initializing Git repository for the first time...
    git init
    if errorlevel 1 (
        echo git init failed.
        pause
        exit /b 1
    )
    git branch -M main
)

for /f "delims=" %%A in ('git remote get-url origin 2^>nul') do set "REMOTE_URL=%%A"
if "%REMOTE_URL%"=="" (
    set /p "REMOTE_URL=Git remote URL: "
    if "%REMOTE_URL%"=="" (
        echo Git remote URL cannot be empty.
        pause
        exit /b 1
    )
    git remote add origin "%REMOTE_URL%"
    if errorlevel 1 (
        echo Failed to add Git remote.
        pause
        exit /b 1
    )
)

for /f "delims=" %%A in ('git config user.name 2^>nul') do set "GIT_NAME=%%A"
if "%GIT_NAME%"=="" (
    set /p "GIT_NAME=Your Git name: "
    if "%GIT_NAME%"=="" (
        echo Git name cannot be empty.
        pause
        exit /b 1
    )
    git config user.name "%GIT_NAME%"
)

for /f "delims=" %%A in ('git config user.email 2^>nul') do set "GIT_EMAIL=%%A"
if "%GIT_EMAIL%"=="" (
    set /p "GIT_EMAIL=Your Git email: "
    if "%GIT_EMAIL%"=="" (
        echo Git email cannot be empty.
        pause
        exit /b 1
    )
    git config user.email "%GIT_EMAIL%"
)

echo.
echo === VCAM Commit and Push ===
set /p "MESSAGE=Commit message: "

if "%MESSAGE%"=="" (
    echo Commit message cannot be empty.
    pause
    exit /b 1
)

echo.
echo [1/3] git add .
git add .
if errorlevel 1 (
    echo git add failed.
    pause
    exit /b 1
)

git diff --cached --quiet
if not errorlevel 1 (
    echo No changes to commit.
    pause
    exit /b 0
)

echo [2/3] git commit
git commit -m "%MESSAGE%"
if errorlevel 1 (
    echo git commit failed.
    pause
    exit /b 1
)

echo [3/3] git push origin main
git push origin main
if errorlevel 1 (
    echo git push failed.
    pause
    exit /b 1
)

git fetch --tags origin >nul 2>&1
git show-ref --tags --quiet
if errorlevel 1 (
    echo No tags found. Creating initial version v1.0.0...
    git tag -a v1.0.0 -m "Version 1.0.0"
    if errorlevel 1 (
        echo Failed to create tag v1.0.0.
        pause
        exit /b 1
    )
    git push origin v1.0.0
    if errorlevel 1 (
        echo Failed to push tag v1.0.0.
        pause
        exit /b 1
    )
)

echo.
echo Commit and push completed successfully.
pause
