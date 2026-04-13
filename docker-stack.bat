@echo off
setlocal EnableDelayedExpansion

set "COMPOSE_FILE=docker-compose\docker-compose.yml"
set "ENV_FILE=docker-compose\.env"
set "WAIT_INIT_SECONDS=30"
set "WAIT_BACKEND_SECONDS=30"
set "PULL_IMAGES=true"
set "DOCKER_COMPOSE_CMD="

if "%~1"=="" goto :usage

set "COMMAND=%~1"
shift

call :resolve_compose_cmd
if errorlevel 1 exit /b 1

if /i "%COMMAND%"=="start" (
    call :parse_start_options %*
    if errorlevel 1 exit /b 1
    call :start_stack
    exit /b %errorlevel%
)
if /i "%COMMAND%"=="stop" (
    call :stop_stack
    exit /b %errorlevel%
)
if /i "%COMMAND%"=="restart" (
    call :parse_start_options %*
    if errorlevel 1 exit /b 1
    call :stop_stack
    call :start_stack
    exit /b %errorlevel%
)
if /i "%COMMAND%"=="help" goto :usage
if /i "%COMMAND%"=="-h" goto :usage
if /i "%COMMAND%"=="--help" goto :usage

echo Unknown command: %COMMAND%
goto :usage

:usage
echo Usage: docker-stack.bat ^<command^> [options]
echo.
echo Commands:
echo   start      Pull images (optional) and start init, backend, then frontend
echo   stop       Stop init, backend, and frontend profiles
echo   restart    Stop then start
echo   help       Show this help message
echo.
echo Options (for start/restart):
echo   --no-pull                  Skip image pull before starting
echo   --wait-init ^<seconds^>      Wait after init profile (default: 30)
echo   --wait-backend ^<seconds^>   Wait after backend profile (default: 30)
exit /b 1

:resolve_compose_cmd
where docker-compose >nul 2>&1
if not errorlevel 1 (
    set "DOCKER_COMPOSE_CMD=docker-compose"
    echo Docker Compose detected: docker-compose
    exit /b 0
)
where docker >nul 2>&1
if not errorlevel 1 (
    docker compose version >nul 2>&1
    if not errorlevel 1 (
        set "DOCKER_COMPOSE_CMD=docker compose"
        echo Docker Compose detected: docker compose
        exit /b 0
    )
)
echo Docker Compose is not installed.
exit /b 1

:check_docker_service
docker info >nul 2>&1
if errorlevel 1 (
    echo Docker service is not active.
    exit /b 1
)
echo Docker service is active.
exit /b 0

:start_stack
call :check_docker_service
if errorlevel 1 exit /b 1

if "%PULL_IMAGES%"=="true" (
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --profile backend --profile frontend pull
    if errorlevel 1 exit /b 1
)

%DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --env-file "%ENV_FILE%" up -d
if errorlevel 1 exit /b 1

echo Waiting for initialization to complete...
timeout /t %WAIT_INIT_SECONDS% /nobreak >nul

%DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile backend --env-file "%ENV_FILE%" up -d
if errorlevel 1 exit /b 1

echo Waiting for backend initialization to complete...
timeout /t %WAIT_BACKEND_SECONDS% /nobreak >nul

%DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile frontend --env-file "%ENV_FILE%" up -d
exit /b %errorlevel%

:stop_stack
%DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --profile backend --profile frontend down
exit /b %errorlevel%

:parse_start_options
if "%~1"=="" exit /b 0
if /i "%~1"=="--no-pull" (
    set "PULL_IMAGES=false"
    shift
    goto :parse_start_options
)
if /i "%~1"=="--wait-init" (
    if "%~2"=="" (
        echo Missing value for --wait-init
        exit /b 1
    )
    set "WAIT_INIT_SECONDS=%~2"
    shift
    shift
    goto :parse_start_options
)
if /i "%~1"=="--wait-backend" (
    if "%~2"=="" (
        echo Missing value for --wait-backend
        exit /b 1
    )
    set "WAIT_BACKEND_SECONDS=%~2"
    shift
    shift
    goto :parse_start_options
)
echo Unknown option: %~1
exit /b 1