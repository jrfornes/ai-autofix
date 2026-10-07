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
            description: 'On E2E Tests failure, publish the @flaky quarantine candidate (never auto-merges)'
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
            description: 'plan = comment the quarantine diff on the PR; apply = commit it onto CHANGE_BRANCH; off = disabled'
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

        stage('Validate Quarantine Gates') {
            steps {
                script {
                    docker.image(env.DOCKER_IMAGE).inside('--privileged --ipc=host') {
                        sh './ci/ai-autofix/validate-gates.sh'
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
                    docker.image(env.DOCKER_IMAGE).inside('--privileged --ipc=host') {
                        sh 'npx nx format:check --base origin/"${CHANGE_TARGET}" --head HEAD'
                    }
                }
            }
        }
        
        stage('Lint') {
            steps {
                script {
                    docker.image(env.DOCKER_IMAGE).inside('--privileged --ipc=host') {
                        sh 'npx nx affected --target=lint --base origin/"${CHANGE_TARGET}"'
                    }
                }
            }
        }
        
        stage('Unit Tests') {
            steps {
                script {
                    docker.image(env.DOCKER_IMAGE).inside('--privileged --ipc=host') {
                        sh 'npx nx affected --target=test --base origin/"${CHANGE_TARGET}"'
                    }
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
                        // Not `?: true`: Elvis would turn a deliberate false back into true.
                        return params.SKIP_E2E_FLAKY_TESTS == null ? true : params.SKIP_E2E_FLAKY_TESTS
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
                    docker.image(env.DOCKER_IMAGE).inside('--privileged --ipc=host') {
                        sh 'npx nx affected --target=build --prod --base origin/"${CHANGE_TARGET}" --exclude=bugs-index,acme-app-proxy-server'
                    }
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
                        if (!fileExists('ci-output.txt')) {
                            echo 'E2E capture skipped: ci-output.txt missing'
                        } else if (!env.DOCKER_IMAGE) {
                            echo 'E2E failure parse skipped: DOCKER_IMAGE not set; no e2e-failure.env'
                        } else {
                            sh 'chmod +x ci/ai-autofix/parse-e2e-failure.sh ci/ai-autofix/isolate-e2e-failure.sh ci/ai-autofix/tag-e2e-flaky.sh'
                            // In the CI image, not on the agent: the image's awk is the one the harness validates.
                            def parseStatus = 0
                            docker.image(env.DOCKER_IMAGE).inside('--privileged --ipc=host') {
                                parseStatus = sh(
                                    script: './ci/ai-autofix/parse-e2e-failure.sh ci-output.txt e2e-failure.env',
                                    returnStatus: true
                                )
                            }
                            if (parseStatus != 0) {
                                echo 'E2E failure parse ambiguous or incomplete; no e2e-failure.env'
                            }
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
                }
            }
        }
        // cleanup runs after failure/success so the E2E chain still has the checkout
        cleanup {
            script {
                deleteDir()
                try {
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
