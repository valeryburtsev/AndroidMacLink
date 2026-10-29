@echo off
rem Run as administrator. Turns the proxy off and removes the capture certificate.
net session >nul 2>&1 || (echo Please right-click this file and choose "Run as administrator". & pause & exit /b 1)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /f
certutil -delstore Root 95EE84A5424D2569DFD467928F242D3B03D15B34
echo.
echo Proxy is OFF and the certificate is removed.
pause
