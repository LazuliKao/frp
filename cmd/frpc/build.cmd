@echo off
SET GOOS=windows
SET GOARCH=amd64
go build -ldflags "-s -w" -o frpc.exe main.go
upx.exe -v -9 frpc.exe 