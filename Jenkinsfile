// Lots 4 et 5 : intégration continue + déploiement continu de Legeni WebApp.
//
//  PR / feature/*  : Qualité (parallèle) -> Build -> Scan Trivy -> Test d'acceptance         (aucun déploiement)
//  main            : ... -> Push registre -> Staging (Ansible) -> Validation -> Production (Ansible)
//
// Credentials Jenkins attendus (aucun secret dans ce fichier) :
//   registry-credentials  Username/Password   identifiant Docker Hub + jeton d'accès
//   kubeconfig            Secret file         kubeconfig-jenkins.yml (généré par provision.yml)
//   ansible-vault-pass    Secret file         contenu de .vault_pass
//   notify-webhook        Secret text         (facultatif) URL de webhook Discord pour les notifications
//
// À adapter : DOCKERHUB_ID ci-dessous (votre identifiant Docker Hub).

def notify(String message) {
    // Notification Discord (facultative) : sans credential 'notify-webhook', on ignore sans faire échouer le build.
    try {
        withCredentials([string(credentialsId: 'notify-webhook', variable: 'HOOK')]) {
            writeJSON file: 'notify.json', json: [content: message]
            sh 'curl -s -H "Content-Type: application/json" -d @notify.json "$HOOK" >/dev/null || true'
        }
    } catch (ignored) {
        echo "Notification non envoyée (credential 'notify-webhook' absent) : ${message}"
    }
}

pipeline {
    agent any

    parameters {
        booleanParam(name: 'SCAN_SECURITE', defaultValue: true,
                     description: 'Scan Trivy (quality gate). Ne décocher que si la base de vulnérabilités est injoignable.')
    }

    environment {
        DOCKERHUB_ID = 'TON_ID_DOCKERHUB'
        IMAGE_REPO   = "${DOCKERHUB_ID}/legeni-webapp"
        CI_NETWORK   = "ci-net-${env.BUILD_NUMBER}"
        CI_CONTAINER = "webapp-ci-${env.BUILD_NUMBER}"
    }

    options {
        timestamps()
        timeout(time: 45, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
        disableConcurrentBuilds()
    }

    stages {
        stage('Init') {
            steps {
                script {
                    env.VERSION = readFile('VERSION').trim()
                    env.TAG     = "${env.VERSION}-${env.BUILD_NUMBER}"      // ex. 1.1.0-37
                    echo "Branche ${env.BRANCH_NAME} - image ${env.IMAGE_REPO}:${env.TAG}"
                }
            }
        }

        stage('Qualité') {
            parallel {
                stage('Tests + couverture') {
                    agent {
                        docker {
                            image 'python:3.12-slim'
                            args '-e HOME=/tmp'
                            reuseNode true
                        }
                    }
                    steps {
                        sh '''
                            python -m venv /tmp/venv
                            /tmp/venv/bin/pip install -q -r requirements.txt -r requirements-dev.txt
                            mkdir -p reports
                            /tmp/venv/bin/pytest --junitxml=reports/junit.xml \
                                --cov=app --cov-report=xml:reports/coverage.xml --cov-fail-under=80
                        '''
                    }
                    post {
                        always {
                            junit allowEmptyResults: true, testResults: 'reports/junit.xml'
                            recordCoverage(tools: [[parser: 'COBERTURA', pattern: 'reports/coverage.xml']])
                        }
                    }
                }

                stage('Lint Python (flake8)') {
                    agent {
                        docker {
                            image 'python:3.12-slim'
                            args '-e HOME=/tmp'
                            reuseNode true
                        }
                    }
                    steps {
                        sh '''
                            python -m venv /tmp/venv
                            /tmp/venv/bin/pip install -q flake8==7.1.1
                            mkdir -p reports
                            /tmp/venv/bin/flake8 --output-file=reports/flake8.txt --tee .
                        '''
                    }
                    post {
                        always {
                            recordIssues(tools: [flake8(pattern: 'reports/flake8.txt')])
                        }
                    }
                }

                stage('Lint Dockerfile (hadolint)') {
                    steps {
                        sh 'docker run --rm -i hadolint/hadolint:v2.12.0 < Dockerfile'
                    }
                }

                stage('Syntaxe Ansible') {
                    steps {
                        dir('ansible') {
                            sh '''
                                ansible-playbook --syntax-check provision.yml
                                ansible-playbook --syntax-check deploy.yml
                            '''
                        }
                    }
                }
            }
        }

        stage('Build image') {
            steps {
                sh '''
                    # Étape "test" du Dockerfile (flake8 + pytest dans l'image), puis image finale
                    docker build --target test -t legeni-webapp:test .
                    docker build --build-arg APP_VERSION=$TAG -t $IMAGE_REPO:$TAG .
                '''
            }
        }

        stage('Scan de sécurité (Trivy)') {
            when { expression { params.SCAN_SECURITE } }
            steps {
                // --exit-code 1 : échec si une vulnérabilité CRITICAL corrigeable est trouvée
                sh '''
                    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy_cache:/root/.cache \
                        aquasec/trivy:0.57.1 image --no-progress --severity CRITICAL --ignore-unfixed \
                        --exit-code 1 $IMAGE_REPO:$TAG
                '''
            }
        }

        stage("Test d'acceptance") {
            steps {
                sh '''
                    docker network create $CI_NETWORK
                    docker run -d --name $CI_CONTAINER --network $CI_NETWORK $IMAGE_REPO:$TAG
                    docker run --rm --network $CI_NETWORK curlimages/curl:8.11.1 \
                        -sf --retry 10 --retry-connrefused --retry-delay 1 http://$CI_CONTAINER:5000/health
                    docker run --rm --network $CI_NETWORK curlimages/curl:8.11.1 \
                        -sf http://$CI_CONTAINER:5000/api/info | grep -q "\\"version\\": *\\"$TAG\\""
                '''
            }
        }

        stage('Push registre') {
            when { branch 'main' }
            steps {
                withCredentials([usernamePassword(credentialsId: 'registry-credentials',
                                                  usernameVariable: 'REG_USER',
                                                  passwordVariable: 'REG_TOKEN')]) {
                    sh '''
                        echo "$REG_TOKEN" | docker login -u "$REG_USER" --password-stdin
                        docker push $IMAGE_REPO:$TAG
                    '''
                }
            }
        }

        stage('Déploiement staging') {
            when { branch 'main' }
            steps {
                withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG_FILE'),
                                 file(credentialsId: 'ansible-vault-pass', variable: 'VAULT_PASS_FILE')]) {
                    dir('ansible') {
                        sh '''
                            export K8S_AUTH_KUBECONFIG="$KUBECONFIG_FILE"
                            ansible-playbook deploy.yml -e target_env=staging \
                                -e app_image=$IMAGE_REPO -e app_version=$TAG \
                                --vault-password-file "$VAULT_PASS_FILE"
                        '''
                    }
                }
            }
        }

        stage('Validation production') {
            when { branch 'main' }
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input message: "Déployer ${env.TAG} en production ?", ok: 'Déployer'
                }
            }
        }

        stage('Déploiement production') {
            when { branch 'main' }
            steps {
                withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG_FILE'),
                                 file(credentialsId: 'ansible-vault-pass', variable: 'VAULT_PASS_FILE')]) {
                    dir('ansible') {
                        sh '''
                            export K8S_AUTH_KUBECONFIG="$KUBECONFIG_FILE"
                            ansible-playbook deploy.yml -e target_env=prod \
                                -e app_image=$IMAGE_REPO -e app_version=$TAG \
                                --vault-password-file "$VAULT_PASS_FILE"
                        '''
                    }
                }
            }
        }
    }

    post {
        always {
            sh 'docker rm -f $CI_CONTAINER 2>/dev/null || true; docker network rm $CI_NETWORK 2>/dev/null || true'
        }
        success {
            script {
                if (env.BRANCH_NAME == 'main') {
                    notify("✅ ${env.JOB_NAME} #${env.BUILD_NUMBER} : ${env.TAG} déployée en production")
                }
            }
        }
        failure {
            script {
                notify("❌ ${env.JOB_NAME} #${env.BUILD_NUMBER} (${env.BRANCH_NAME}) en échec : ${env.BUILD_URL}console")
            }
        }
    }
}
