@echo off
chcp 65001 >nul
title Stable EA Sync
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0sync-ea.ps1"
