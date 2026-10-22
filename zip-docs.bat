@echo off
powershell.exe -NoProfile -Command "Compress-Archive -LiteralPath '%~dp0docs','%~dp0README.md' -DestinationPath '%~dp0docs.zip' -Force"

if %ERRORLEVEL% neq 0 (
    echo Failed to create ZIP.
    ) else (
        echo Successfully created docs.zip
        )

        pause