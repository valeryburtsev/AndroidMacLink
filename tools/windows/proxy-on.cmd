@echo off
rem Run as administrator. Trusts the capture proxy certificate and routes this user through the proxy on the Mac.
net session >nul 2>&1 || (echo Please right-click this file and choose "Run as administrator". & pause & exit /b 1)
certutil -addstore -f Root "%~dp0mitmproxy-ca-cert.cer" || (echo Certificate import failed. & pause & exit /b 1)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /t REG_SZ /d 192.168.140.1:8080 /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyOverride /t REG_SZ /d "<local>" /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 1 /f
echo.
echo Proxy is ON. Close Phone Link completely and open it again.
pause
