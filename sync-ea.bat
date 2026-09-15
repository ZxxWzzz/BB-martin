@echo off
chcp 65001 >nul
title 美分马丁-stable EA 同步
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0sync-ea.ps1"
