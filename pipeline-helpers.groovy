/**
 * Run a command and capture truncated stdout/stderr to ci-output.txt.
 * Callers must pass captureBytes (CPS-safe; no default param).
 * @param stageName The name of the stage (sets FAILED_STAGE on failure).
 * @param command The command to run inside the CI Docker image.
 * @param captureBytes Max bytes retained in ci-output.txt (tail).
 */
def runCaptured(String stageName, String command, int captureBytes) {
    try {
        docker.image(env.DOCKER_IMAGE).inside('--privileged --ipc=host') {
            // Capture truncated stdout/stderr to ci-output.txt for the E2E
            // identity parse; keep cmd exit status.
            sh '''#!/usr/bin/env bash
                set -uo pipefail
                ''' + command + ''' 2>&1 | tee /tmp/ci-stage-out.txt
                status=${PIPESTATUS[0]}
                tail -c ''' + captureBytes + ''' /tmp/ci-stage-out.txt > ci-output.txt
                exit "${status}"
            '''
        }
    } catch (err) {
        env.FAILED_STAGE = stageName
        throw err
    }
}

return this
