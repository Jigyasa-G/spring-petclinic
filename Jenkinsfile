pipeline {
    agent any
    
    tools {
        maven 'Maven'
        jdk 'JDK17'
    }
    
    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }
        
        stage('Build') {
            steps {
                sh 'mvn clean package -DskipTests'
            }
        }
        
        stage('Test') {
            steps {
                sh 'mvn test'
            }
            post {
                always {
                    junit '**/target/surefire-reports/*.xml'
                }
            }
        }
        
        stage('SonarQube Analysis') {
            steps {
                withSonarQubeEnv('SonarQube') {
                    sh 'mvn sonar:sonar'
                }
            }
        }
        
        stage('OWASP Dependency Check') {
            steps {
                sh 'mvn org.owasp:dependency-check-maven:check'
            }
            post {
                always {
                    dependencyCheckPublisher pattern: 'target/dependency-check-report.xml'
                }
            }
        }
        
        stage('Build Docker Image') {
            steps {
                sh 'docker build -t spring-petclinic:${BUILD_NUMBER} .'
            }
        }
        
        stage('OWASP ZAP Scan') {
            steps {
                sh '''
                docker run --rm --network=devsecops-network -v $(pwd)/zap-report:/zap/wrk/:rw owasp/zap2docker-stable zap-baseline.py \
                -t http://jenkins:8080 -g gen.conf -r zap-report.html
                '''
            }
            post {
                always {
                    publishHTML(target: [
                        allowMissing: false,
                        alwaysLinkToLastBuild: true,
                        keepAll: true,
                        reportDir: 'zap-report',
                        reportFiles: 'zap-report.html',
                        reportName: 'ZAP Security Report'
                    ])
                }
            }
        }
        
        stage('Deploy to Production') {
            steps {
                ansiblePlaybook(
                    playbook: 'deploy/playbook.yml',
                    inventory: 'deploy/inventory',
                    extraVars: [
                        build_number: env.BUILD_NUMBER
                    ]
                )
            }
        }
    }
    
    post {
        always {
            cleanWs()
        }
    }
}