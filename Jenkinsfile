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
        
        // stage('Test') {
        //     steps {
        //         sh 'mvn test -Dtest=!*Postgres*'
        //     }
        //     post {
        //         always {
        //             junit '**/target/surefire-reports/*.xml'
        //         }
        //     }
        // }
        
        stage('SonarQube Analysis') {
            steps {
                // withSonarQubeEnv('SonarQube') {
                //     sh 'mvn sonar:sonar'
                // }
                withSonarQubeEnv('SonarQube') {
                    withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
                        sh '''
                            mvn sonar:sonar \
                            -Dsonar.host.url=http://sonarqube:9000 \
                            -Dsonar.login=${SONAR_TOKEN}
                        '''
                    }
                }
            }
        }
        
        stage('OWASP Dependency Check') {
            when {
                expression { return false }  // Skip this stage
            }
            steps {
                sh 'mkdir -p /var/jenkins_home/owasp-dc-cache'
                sh 'mvn org.owasp:dependency-check-maven:check -DcacheDirectory=/var/jenkins_home/owasp-dc-cache'
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
                # Clean up any existing containers first
                docker stop petclinic-app || true
                docker rm petclinic-app || true
                
                # Start the application
                docker run -d --name petclinic-app --network=devsecops-network -p 8081:8080 spring-petclinic:${BUILD_NUMBER}
                
                # Wait for app to start
                sleep 20
                
                # Create a simple report instead of using the zap files directly
                echo "<html><head><title>ZAP Security Report</title></head><body>" > zap-report.html
                echo "<h1>ZAP Security Scan Results</h1>" >> zap-report.html
                echo "<pre>" >> zap-report.html
                
                # Run ZAP scan and append output to our report
                docker run --rm --network=devsecops-network ghcr.io/zaproxy/zaproxy:stable zap-baseline.py \
                -t http://petclinic-app:8080 -I >> zap-report.html
                
                echo "</pre></body></html>" >> zap-report.html
                
                # Move the report to the proper directory
                mkdir -p zap-report
                mv zap-report.html zap-report/
                
                # Stop the container after scan
                docker stop petclinic-app || true
                docker rm petclinic-app || true
                '''
            }
            post {
                always {
                    publishHTML(target: [
                        allowMissing: true,
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