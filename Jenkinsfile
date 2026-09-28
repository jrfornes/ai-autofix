def helpers

pipeline {
    agent {
        label 'node_ui'
    }
    
    parameters {
        booleanParam(
            name: 'SKIP_E2E_TESTS',
            defaultValue: false,
            description: 'Skip E2E tests (including flaky tests)'
        )
        booleanParam(
            name: 'SKIP_E2E_FLAKY_TESTS',
            defaultValue: true,
            description: 'Skip E2E flaky tests (only flaky tests)'
        )
        booleanParam(
            name: 'SKIP_CHANGE_ANALYSIS',
            defaultValue: true,
            description: 'Skip Change Analysis'
        )
        booleanParam(
            name: 'ENABLE_AI_AUTOFIX',
            defaultValue: false,
            description: 'On format/lint/unit/build failure, run CI auto-fix (never auto-merges)'
        )
        booleanParam(
            name: 'SKIP_E2E_ISOLATION',
            defaultValue: false,
            description: 'Skip Phase C isolated re-run of the failed E2E (after parse)'
        )
        booleanParam(
            name: 'SKIP_E2E_QUARANTINE',
            defaultValue: false,
            description: 'Skip Phase D @flaky quarantine patch after isolation pass'
        )
        choice(
            name: 'AI_AUTOFIX_MODE',
            choices: ['plan', 'apply', 'off'],
            description: 'plan = comment verified diff; apply = open sibling PR into CHANGE_BRANCH; off = disabled'
        )
    }
    
    options {
        timeout(time: 5, unit: 'HOURS')
        disableConcurrentBuilds()
        ansiColor('xterm')
    }
    
    environment {
        HOME = "${WORKSPACE}"
        NO_COLOR="1"
        CYPRESS_CACHE_FOLDER = "cache/Cypress"
        CYPRESS_VERIFY_TIMEOUT = "100000"
        NX_PARALLEL_E2E = "2"
        NODE_OPTIONS = "--max_old_space_size=8192"
        AI_AUTOFIX_ARTIFACT_DIR = "${WORKSPACE}/../ai-autofix-${BUILD_NUMBER}"
    }
    
    stages {
        stage('Checkout') {
            steps {
                deleteDir()
                checkout scm
                script {
                    helpers = load 'ci/pipeline-helpers.groovy'
                }
            }
        }
        
        stage('Build Docker Image') {
            steps {
                script {
                    env.DOCKER_IMAGE = docker.build("acme-ui-ci", "-f ./ci/Dockerfile .").id
                }
            }
        }
        
        stage('Compile') {
            steps {
                script {
                    docker.image(env.DOCKER_IMAGE).inside('--privileged --ipc=host') {
                        sh 'npm ci'
                    }
                }
            }
        }

        stage('Change Analysis') {
            when {
                not { 
                    expression { 
                        return params.SKIP_CHANGE_ANALYSIS ?: false 
                    }
                }
            }
            steps {
                script {
                    docker.image(env.DOCKER_IMAGE).inside('--privileged --ipc=host') {
                        sh 'npx nx run change-analysis:run --base=origin/"${CHANGE_TARGET}" --head=HEAD'
                    }
                }
            }
        }
        
        stage('Check Format') {
            steps {
                script {
                    helpers.runCaptured(
                        'Check Format',
                        'npx nx format:check --base origin/"${CHANGE_TARGET}" --head HEAD',
                        204800
                    )
                }
            }
        }
        
        stage('Lint') {
            steps {
                script {
                    helpers.runCaptured(
                        'Lint',
                        'npx nx affected --target=lint --base origin/"${CHANGE_TARGET}"',
                        204800
                    )
                }
            }
        }
        
        stage('Unit Tests') {
            steps {
                script {
                    helpers.runCaptured(
                        'Unit Tests',
                        'npx nx affected --target=test --base origin/"${CHANGE_TARGET}"',
                        204800
                    )
                }
            }
        }
        
        stage('E2E Tests') {
            when {
                not { 
                    expression { 
                        return params.SKIP_E2E_TESTS ?: false 
                    }
                }
            }
            steps {
                script {
                    helpers.runCaptured(
                        'E2E Tests',
                        './ci/nx-e2e-affected.sh "${CHANGE_TARGET}" "-@flaky"',
                        2097152
                    )
                }
            }
        }
        
        stage('E2E Tests - Flaky') {
            when {
                not { 
                    expression { 
                        return params.SKIP_E2E_FLAKY_TESTS ?: true 
                    }
                }
            }
            steps {
                script {
                    docker.image(env.DOCKER_IMAGE).inside('--privileged --ipc=host') {
                        def result = sh(
                            script: './ci/nx-e2e-affected.sh "${CHANGE_TARGET}" "@flaky"',
                            returnStatus: true
                        )
                        if (result != 0) {
                            echo "E2E Flaky tests failed, continuing build."
                        }
                    }
                }
            }
        }
        
        stage('Build') {
            steps {
                script {
                    helpers.runCaptured(
                        'Build',
                        'npx nx affected --target=build --prod --base origin/"${CHANGE_TARGET}" --exclude=bugs-index,acme-app-proxy-server',
                        204800
                    )
                }
            }
        }
    }
    
    post {
        failure {
            script {
                // Phase B + C + D: E2E identity parse, isolate, optional @flaky patch (not autofix-eligible).
                if (env.FAILED_STAGE == 'E2E Tests') {
                    try {
                        if (fileExists('ci-output.txt')) {
                            sh 'chmod +x ci/ai-autofix/parse-e2e-failure.sh ci/ai-autofix/isolate-e2e-failure.sh ci/ai-autofix/tag-e2e-flaky.sh'
                            def parseStatus = sh(
                                script: './ci/ai-autofix/parse-e2e-failure.sh ci-output.txt e2e-failure.env',
                                returnStatus: true
                            )
                            if (parseStatus != 0) {
                                echo 'E2E failure parse ambiguous or incomplete; no e2e-failure.env'
                            }
                        } else {
                            echo 'E2E capture skipped: ci-output.txt missing'
                        }

                        // Phase C: isolate one failing test when parse produced an env file.
                        if (fileExists('e2e-failure.env')) {
                            withEnv([
                                "SKIP_E2E_ISOLATION=${params.SKIP_E2E_ISOLATION ?: false}"
                            ]) {
                                if (params.SKIP_E2E_ISOLATION) {
                                    sh './ci/ai-autofix/isolate-e2e-failure.sh e2e-failure.env e2e-isolation.env'
                                } else if (!env.DOCKER_IMAGE) {
                                    echo 'E2E isolation: DOCKER_IMAGE not set; writing error verdict'
                                    sh 'ISOLATE_E2E_NO_DOCKER=1 ./ci/ai-autofix/isolate-e2e-failure.sh e2e-failure.env e2e-isolation.env'
                                } else {
                                    catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                                        docker.image(env.DOCKER_IMAGE).inside('--privileged --ipc=host') {
                                            sh(
                                                script: './ci/ai-autofix/isolate-e2e-failure.sh e2e-failure.env e2e-isolation.env',
                                                returnStatus: true
                                            )
                                        }
                                    }
                                }
                            }
                        } else {
                            echo 'E2E isolation skipped: e2e-failure.env missing'
                        }

                        // Phase D: on isolation pass, emit gated @flaky quarantine patch (no push).
                        if (fileExists('e2e-isolation.env')) {
                            withEnv([
                                "SKIP_E2E_QUARANTINE=${params.SKIP_E2E_QUARANTINE ?: false}"
                            ]) {
                                if (params.SKIP_E2E_QUARANTINE) {
                                    sh './ci/ai-autofix/tag-e2e-flaky.sh e2e-isolation.env e2e-quarantine.patch e2e-quarantine.env'
                                } else if (!env.DOCKER_IMAGE) {
                                    echo 'E2E quarantine: DOCKER_IMAGE not set; skipping tag'
                                } else {
                                    catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                                        docker.image(env.DOCKER_IMAGE).inside('--privileged --ipc=host') {
                                            sh(
                                                script: './ci/ai-autofix/tag-e2e-flaky.sh e2e-isolation.env e2e-quarantine.patch e2e-quarantine.env',
                                                returnStatus: true
                                            )
                                        }
                                    }
                                }
                            }
                        } else {
                            echo 'E2E quarantine skipped: e2e-isolation.env missing'
                        }

                        archiveArtifacts(
                            artifacts: 'ci-output.txt,e2e-failure.env,e2e-isolation.env,e2e-quarantine.patch,e2e-quarantine.env',
                            fingerprint: true,
                            allowEmptyArchive: true
                        )
                    } catch (Exception e) {
                        echo "E2E capture/parse/isolation/quarantine skipped: ${e.message}"
                    }
                }

                if (!(params.ENABLE_AI_AUTOFIX ?: false) || params.AI_AUTOFIX_MODE == 'off') {
                    echo 'AI autofix skipped: ENABLE_AI_AUTOFIX is false or mode=off'
                    return
                }

                // Phase E: publish gated @flaky quarantine (comment or push to CHANGE_BRANCH).
                if (env.FAILED_STAGE == 'E2E Tests') {
                    if (fileExists('e2e-quarantine.env') && fileExists('e2e-quarantine.patch')) {
                        withCredentials([string(credentialsId: 'acme-ui-bitbucket-token', variable: 'BITBUCKET_AUTOFIX_TOKEN')]) {
                            withEnv([
                                "AI_AUTOFIX_MODE=${params.AI_AUTOFIX_MODE}",
                                "CHANGE_BRANCH=${env.CHANGE_BRANCH ?: ''}",
                                "CHANGE_ID=${env.CHANGE_ID ?: ''}",
                                "BUILD_URL=${env.BUILD_URL ?: ''}"
                            ]) {
                                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                                    sh '''
                                        set -euo pipefail
                                        chmod +x ci/ai-autofix/*.sh
                                        if [[ ! -s e2e-quarantine.patch ]]; then
                                          echo '[ai-autofix] e2e-quarantine.patch empty; nothing to publish'
                                          exit 0
                                        fi
                                        set -a
                                        # shellcheck disable=SC1091
                                        source e2e-quarantine.env
                                        set +a
                                        case "${AI_AUTOFIX_MODE}" in
                                          plan)
                                            ./ci/ai-autofix/comment-bitbucket-pr.sh e2e-quarantine.patch
                                            ;;
                                          apply)
                                            ./ci/ai-autofix/push-e2e-quarantine.sh e2e-quarantine.patch
                                            ;;
                                          *)
                                            echo "[ai-autofix] mode ${AI_AUTOFIX_MODE} not publishable for E2E; skipping"
                                            ;;
                                        esac
                                    '''
                                }
                            }
                        }
                    } else {
                        echo '[ai-autofix] E2E quarantine artifacts missing; nothing to publish'
                    }
                    return
                }

                def eligible = ['Check Format', 'Lint']
                if (!eligible.contains(env.FAILED_STAGE)) {
                    echo "AI autofix skipped: stage '${env.FAILED_STAGE}' is not eligible"
                    return
                }
                if (!env.DOCKER_IMAGE) {
                    echo 'AI autofix skipped: DOCKER_IMAGE not set'
                    return
                }

                def failed = env.FAILED_STAGE
                def artifactDir = env.AI_AUTOFIX_ARTIFACT_DIR
                def dockerArgs = "--privileged --ipc=host -v ${artifactDir}:${artifactDir}"

                try {
                    sh "mkdir -p '${artifactDir}'"

                    // Phase A: deterministic Format/Lint only — no Cursor credential
                    withEnv([
                        "FAILED_STAGE=${failed}",
                        "AI_AUTOFIX_MODE=${params.AI_AUTOFIX_MODE}",
                        "AI_AUTOFIX_ARTIFACT_DIR=${artifactDir}"
                    ]) {
                        catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                            docker.image(env.DOCKER_IMAGE).inside(dockerArgs) {
                                sh 'chmod +x ci/ai-autofix/*.sh && ./ci/ai-autofix/run.sh'
                            }
                        }
                    }

                    if (fileExists("${artifactDir}/autofix.env")) {
                        withCredentials([string(credentialsId: 'acme-ui-bitbucket-token', variable: 'BITBUCKET_AUTOFIX_TOKEN')]) {
                            withEnv([
                                "FAILED_STAGE=${failed}",
                                "AI_AUTOFIX_MODE=${params.AI_AUTOFIX_MODE}",
                                "AI_AUTOFIX_ARTIFACT_DIR=${artifactDir}"
                            ]) {
                                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                                    docker.image(env.DOCKER_IMAGE).inside(dockerArgs) {
                                        sh './ci/ai-autofix/publish.sh'
                                    }
                                }
                            }
                        }
                    } else {
                        echo '[ai-autofix] no verified patch produced; nothing to publish'
                    }
                } catch (Exception e) {
                    echo "AI autofix skipped: ${e.message}"
                }
            }
        }
        // cleanup runs after failure/success so autofix still has the checkout
        cleanup {
            script {
                deleteDir()
                try {
                    if (env.AI_AUTOFIX_ARTIFACT_DIR) {
                        dir(env.AI_AUTOFIX_ARTIFACT_DIR) { deleteDir() }
                    }
                    dir("${workspace}@tmp") { deleteDir() }
                    dir("${workspace}@script") { deleteDir() }
                    dir("${workspace}@script@tmp") { deleteDir() }
                } catch (Exception e) {
                    echo "Warning: Failed to clean up temporary directories: ${e.message}"
                }
            }
        }
    }
}
