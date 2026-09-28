@echo off
echo Installing Python dependencies for AI Pose Server...
pip install -r requirements.txt
if %errorlevel% neq 0 (
    echo.
    echo ERROR: pip failed. Make sure Python is installed and in PATH.
    pause
    exit /b 1
)
echo.
echo Done! You can now use the pose-from-image and motion capture tools.
pause
