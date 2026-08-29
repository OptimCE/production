@echo off
setlocal EnableDelayedExpansion

set "COMPOSE_FILE=docker-compose\docker-compose.yml"
set "ENV_FILE=docker-compose\.env"
set "WAIT_INIT_SECONDS=30"
set "WAIT_BACKEND_SECONDS=30"
set "PULL_IMAGES=true"
set "MIGRATE_DRY_RUN=false"
set "DOCKER_COMPOSE_CMD="

if "%~1"=="" goto :usage

set "COMMAND=%~1"
shift
set "REST="
:collect_args
if "%~1"=="" goto :done_collect
set "REST=!REST! %~1"
shift
goto :collect_args
:done_collect

call :resolve_compose_cmd
if errorlevel 1 exit /b 1

if /i "%COMMAND%"=="start" (
    call :parse_start_options !REST!
    if errorlevel 1 exit /b 1
    call :start_stack
    exit /b %errorlevel%
)
if /i "%COMMAND%"=="stop" (
    call :stop_stack
    exit /b %errorlevel%
)
if /i "%COMMAND%"=="restart" (
    call :parse_start_options !REST!
    if errorlevel 1 exit /b 1
    call :stop_stack
    call :start_stack
    exit /b %errorlevel%
)
if /i "%COMMAND%"=="migrate" (
    call :parse_migrate_options !REST!
    if errorlevel 1 exit /b 1
    call :migrate_stack
    exit /b %errorlevel%
)
if /i "%COMMAND%"=="verify" (
    call :verify_stack
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
echo   migrate    Apply pending database migrations, then re-converge the grants
echo   verify     Prove the database isolation and the CRM grant matrix
echo   help       Show this help message
echo.
echo Options (for start/restart):
echo   --no-pull                  Skip image pull before starting
echo   --wait-init ^<seconds^>      Wait after init profile (default: 30)
echo   --wait-backend ^<seconds^>   Wait after backend profile (default: 30)
echo.
echo Options (for migrate):
echo   --no-pull                  Skip the optimce-migrator image pull
echo   --dry-run                  Report pending migrations without applying them
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

call :check_frontend_config
if errorlevel 1 exit /b 1

%DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile frontend --env-file "%ENV_FILE%" up -d
exit /b %errorlevel%

:check_frontend_config
rem crm-frontend bind-mounts a SINGLE FILE, config.json, over the one inside the
rem image. Docker creates a missing bind source as a DIRECTORY, and nginx then
rem serves a directory where the SPA expects its configuration: the app loads to a
rem blank page with nothing useful in any log.
rem
rem The obvious fix - depends_on: crm-frontend-config on crm-frontend - is not
rem available: crm-frontend-config is in the `init` profile and crm-frontend in
rem `frontend`, and compose rejects a depends_on target that is not in an enabled
rem profile ("depends on undefined service"). It would break --profile frontend
rem up -d outright. This check is the substitute; `start` runs the init profile
rem first, so by here the file must exist.
set "FRONTEND_CFG=docker-compose\crm-frontend-config\config.json"

if exist "%FRONTEND_CFG%\" (
    echo ERROR: %FRONTEND_CFG% is a DIRECTORY.
    echo Docker created it because the init profile had not rendered the file yet.
    echo Remove it and re-run the init profile:
    echo     rmdir "%FRONTEND_CFG%"
    echo     %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --env-file "%ENV_FILE%" up -d
    exit /b 1
)

if not exist "%FRONTEND_CFG%" (
    echo ERROR: %FRONTEND_CFG% does not exist.
    echo It is rendered from config.template.json by the init profile.
    echo Run the init profile before the frontend profile.
    exit /b 1
)
exit /b 0

:stop_stack
echo Running backups before stopping...
call :do_backup
%DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile init --profile backend --profile frontend down
exit /b %errorlevel%

:do_backup
rem Two jobs, because there are two instances. db-backup loops the five application
rem databases plus the cluster globals; keycloak-db-backup covers the separate
rem Keycloak instance. A failure is reported but does not abort the other job.
for %%J in (db-backup keycloak-db-backup) do (
    echo Running %%J...
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --env-file "%ENV_FILE%" --profile backup run --rm %%J
    if errorlevel 1 echo %%J failed
)
echo Backups completed.
exit /b 0

:verify_stack
rem Runs both scripts inside the postgres-init image, so no psql is needed on the
rem host and all five role passwords come from the environment compose already
rem assembles. cmd.exe does not rewrite container paths, so no MSYS_NO_PATHCONV
rem here — unlike docker-stack.sh under Git Bash.
set "VERIFY_STATUS=0"

echo Proving database isolation...
%DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile backend --env-file "%ENV_FILE%" run --rm --no-deps --entrypoint sh postgres-init /postgres/verify/isolation.sh
if errorlevel 1 set "VERIFY_STATUS=1"

echo.
echo Proving every granted CRM write lands...
%DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile backend --env-file "%ENV_FILE%" run --rm --no-deps --entrypoint sh postgres-init /postgres/verify/positive-writes.sh
if errorlevel 1 set "VERIFY_STATUS=1"

if "%VERIFY_STATUS%"=="1" (
    echo.
    echo Verification FAILED. See docker-compose\postgres\README.md.
    exit /b 1
)
echo.
echo Verification passed.
exit /b 0

:migrate_stack
rem The migrator is in the `migration` profile but depends_on postgres and
rem postgres-init, which are in `backend` - so BOTH profiles must be active or
rem compose refuses the project with "depends on undefined service". Naming the
rem service keeps the run scoped to it; its dependencies are already up.
call :check_docker_service
if errorlevel 1 exit /b 1

if "%PULL_IMAGES%"=="true" (
    %DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile backend --profile migration pull optimce-migrator
    if errorlevel 1 exit /b 1
)

if "%MIGRATE_DRY_RUN%"=="true" goto :migrate_dry_run

echo Applying pending migrations...
echo.
echo NOTE: the annexe migrations take ACCESS EXCLUSIVE on generation/simulation.
echo       With lock_timeout at its default of 0, a running allocation-key or
echo       simulation-key worker holding a transaction makes this wait forever -
echo       and every later query then queues behind it. Stop those four services
echo       first, or run this before the backend profile is up.
echo.

rem Each migration commits in its own transaction, so a failure part-way leaves
rem earlier ones APPLIED and ungranted. postgres-init must run over whatever landed
rem BEFORE we report the failure - a missing CRM grant is silent at runtime. Hence
rem the explicit status flag rather than `exit /b %errorlevel%`, which would carry
rem the exit code of postgres-init instead.
set "MIGRATE_STATUS=0"
%DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile backend --profile migration --env-file "%ENV_FILE%" run --rm optimce-migrator
if errorlevel 1 set "MIGRATE_STATUS=1"

echo.
echo Re-converging grants over whatever the migrator created...
%DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile backend --env-file "%ENV_FILE%" run --rm postgres-init

if "%MIGRATE_STATUS%"=="1" (
    echo.
    echo Migration FAILED. Grants were converged over what landed.
    echo See DATABASE_CONSOLIDATION.md 9.1 before retrying.
    exit /b 1
)
echo.
echo Migrations applied and grants converged. Run docker-stack.bat verify next.
exit /b 0

:migrate_dry_run
echo Reporting pending migrations (nothing will be applied)...
%DOCKER_COMPOSE_CMD% -f "%COMPOSE_FILE%" --profile backend --profile migration --env-file "%ENV_FILE%" run --rm optimce-migrator --dry-run
exit /b %errorlevel%

:parse_migrate_options
if "%~1"=="" exit /b 0
if /i "%~1"=="--no-pull" (
    set "PULL_IMAGES=false"
    shift
    goto :parse_migrate_options
)
if /i "%~1"=="--dry-run" (
    set "MIGRATE_DRY_RUN=true"
    shift
    goto :parse_migrate_options
)
echo Unknown option: %~1
exit /b 1

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