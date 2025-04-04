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
        
        stage('Start PostgreSQL') {
            steps {
                sh '''
                # Check if network exists, create if it doesn't
                docker network inspect devsecops-network >/dev/null 2>&1 || docker network create devsecops-network
                
                # Stop any existing postgres container
                docker stop postgres-test || true
                docker rm postgres-test || true
                
                # Start a Postgres container for testing
                docker run -d --name postgres-test \
                  --network=devsecops-network \
                  -p 5432:5432 \
                  -e POSTGRES_USER=petclinic \
                  -e POSTGRES_PASSWORD=petclinic \
                  -e POSTGRES_DB=petclinic \
                  postgres:17.0
                  
                # Give PostgreSQL time to initialize
                sleep 10
                '''
            }
        }
        
        stage('Build') {
            steps {
                sh 'mvn clean package -DskipTests'
            }
        }
        
        stage('Test') {
            steps {
                sh '''
                mvn test \
                -DPOSTGRES_URL=jdbc:postgresql://localhost:15432/petclinic \
                -Dspring.docker.compose.skip.in-tests=true \
                -Dspring.profiles.active=postgres \
                -Dspring.datasource.username=petclinic \
                -Dspring.datasource.password=petclinic \
                -Dspring.datasource.driver-class-name=org.postgresql.Driver \
                -Dspring.jpa.database-platform=org.hibernate.dialect.PostgreSQLDialect \
                -Dspring.jpa.hibernate.ddl-auto=update
                '''
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
            sh 'docker stop postgres-test || true'
            sh 'docker rm postgres-test || true'
            cleanWs()
        }
    }
}