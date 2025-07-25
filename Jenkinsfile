pipeline {
    agent any

    parameters {
        string(name: 'REPO_NAME', defaultValue: 'default-repo-name', description: 'The name of the Meesho GitHub repository to analyze.')
    }

    environment {
        // These credentials must be configured in Jenkins under 'Manage Jenkins' -> 'Credentials'.
        // Use 'Secret text' for tokens/keys and 'Secret file' for the GCS key.
        GITHUB_TOKEN                = credentials('dynamic-config-audit-github-token')
        GEMINI_API_KEY              = credentials('dynamic-config-audit-gemini-api-key')
        GCS_SERVICE_ACCOUNT_KEY_TMP = credentials('dynamic-config-audit-gcs-key')
    }

    stages {
        stage('Checkout') {
            steps {
                // Ensure we are in the main workspace directory and clean it
                dir(pwd()) {
                    // Clones the repository containing this Jenkinsfile.
                    echo "Checking out source code..."
                    checkout scm
                    
                    // List files for debugging to ensure checkout was successful
                    echo "Files in workspace after checkout:"
                    sh 'ls -la'
                }
            }
        }

        stage('Run Analysis Script') {
            steps {
                script {
                    try {
                        env.GCS_SERVICE_ACCOUNT_KEY_PATH = GCS_SERVICE_ACCOUNT_KEY_TMP

                        sh 'chmod +x scripts/init.sh'

                        echo "Starting analysis for repository: ${params.REPO_NAME}"
                        sh "./scripts/init.sh ${params.REPO_NAME}"

                    } catch (e) {
                        echo "Error during script execution: ${e.message}"
                        currentBuild.result = 'FAILURE'
                        error "Pipeline failed."
                    }
                }
            }
        }
    }

    post {
        always {
            echo 'Pipeline finished.'
            // The cleanup trap in init.sh will handle removing the cloned repository.
        }
    }
} 