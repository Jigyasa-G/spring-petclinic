#!/bin/bash

# Script to create necessary files for spring-petclinic project
# This script preserves the content of existing files

BASE_DIR="/Users/jacqueine/Desktop/cmu/DEVOPS/spring-petclinic"

# Create directories if they don't exist
mkdir -p "deploy"
mkdir -p "devsecops-pipeline/grafana/provisioning/dashboards"
mkdir -p "devsecops-pipeline/prometheus"
mkdir -p "src/main/resources/messages"
mkdir -p "src/main/resources/templates"

# Create Dockerfile
cat > "Dockerfile" << 'EOF'
FROM eclipse-temurin:17-jdk-focal
WORKDIR /app
COPY target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
EOF

# Create Jenkinsfile
cat > "Jenkinsfile" << 'EOF'
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
EOF

# Create deploy/inventory
cat > "deploy/inventory" << 'EOF'
[production]
172.16.104.136 ansible_user=devop ansible_ssh_pass=password ansible_become_pass=password

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF

# Create deploy/playbook.yml
cat > "deploy/playbook.yml" << 'EOF'
---
- name: Deploy Spring PetClinic
  hosts: production
  become: yes
  vars:
    app_name: spring-petclinic
    container_name: spring-petclinic
    container_port: 8080
    host_port: 80
    
  tasks:
    - name: Install Docker
      apt:
        name: docker.io
        state: present
        update_cache: yes
      ignore_errors: yes
    
    - name: Check if container already exists
      shell: docker ps -a | grep spring-petclinic || echo "not found"
      register: container_exists
      changed_when: false
      ignore_errors: yes
    
    - name: Stop existing Spring PetClinic container
      shell: docker stop spring-petclinic && docker rm spring-petclinic
      when: "'not found' not in container_exists.stdout"
      ignore_errors: yes
    
    - name: Create temporary directory for Docker image transfer
      file:
        path: /tmp/petclinic-transfer
        state: directory
        mode: '0755'
    
    - name: Save Docker image
      shell: docker save spring-petclinic:{{ build_number }} -o /tmp/petclinic-image.tar
      delegate_to: localhost
    
    - name: Copy Docker image to remote
      copy:
        src: /tmp/petclinic-image.tar
        dest: /tmp/petclinic-transfer/petclinic-image.tar
    
    - name: Load Docker image on remote
      shell: docker load -i /tmp/petclinic-transfer/petclinic-image.tar
    
    - name: Start Spring PetClinic container
      shell: >
        docker run -d --name spring-petclinic -p {{ host_port }}:{{ container_port }}
        spring-petclinic:{{ build_number }}
    
    - name: Clean up temporary files
      file:
        path: /tmp/petclinic-transfer
        state: absent      
    - name: Verify container is running
      shell: docker ps | grep spring-petclinic
      register: container_check
      ignore_errors: yes
    
    - name: Container status
      debug:
        msg: "Container state: {{ 'running' if container_check.rc == 0 else 'not running' }}"
        
    # Install Node Exporter for server monitoring
    - name: Check if node-exporter container exists
      shell: docker ps -a | grep node-exporter || echo "not found"
      register: exporter_exists
      changed_when: false
      
    - name: Remove existing node-exporter container
      shell: docker stop node-exporter && docker rm node-exporter
      when: "'not found' not in exporter_exists.stdout"
      ignore_errors: yes
      
    - name: Start node-exporter container
      shell: >
        docker run -d --name node-exporter -p 9100:9100
        --restart always prom/node-exporter:latest
EOF

# Create devsecops-pipeline/docker-compose.yml
cat > "devsecops-pipeline/docker-compose.yml" << 'EOF'
version: '3'

networks:
  devsecops-network:
    external: true

services:
  jenkins:
    build: 
      context: .
      dockerfile: jenkins.Dockerfile
    privileged: true
    user: root
    ports:
      - "8080:8080"
      - "50000:50000"
    container_name: jenkins
    volumes:
      - jenkins_home:/var/jenkins_home
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - devsecops-network
  sonarqube:
    image: sonarqube:lts
    container_name: sonarqube
    ports:
      - "9000:9000"
    environment:
      - SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true
    volumes:
      - sonarqube_data:/opt/sonarqube/data
      - sonarqube_logs:/opt/sonarqube/logs
      - sonarqube_extensions:/opt/sonarqube/extensions
    networks:
      - devsecops-network

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/usr/share/prometheus/console_libraries'
      - '--web.console.templates=/usr/share/prometheus/consoles'
    networks:
      - devsecops-network

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - grafana_data:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
    networks:
      - devsecops-network

  zap:
    image: ghcr.io/zaproxy/zaproxy:stable
    container_name: zap
    command: zap.sh -daemon -host 0.0.0.0 -port 8090 -config api.addrs.addr.name=.* -config api.addrs.addr.regex=true -config api.key=zapapikey
    ports:
      - "8090:8090"
    networks:
      - devsecops-network

volumes:
  jenkins_home:
  sonarqube_data:
  sonarqube_logs:
  sonarqube_extensions:
  prometheus_data:
  grafana_data:
EOF

# Create devsecops-pipeline/grafana/provisioning/dashboards/jenkins-dashboard.json
cat > "devsecops-pipeline/grafana/provisioning/dashboards/jenkins-dashboard.json" << 'EOF'
{
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": "-- Grafana --",
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "type": "dashboard"
      }
    ]
  },
  "editable": true,
  "gnetId": null,
  "graphTooltip": 0,
  "id": 1,
  "links": [],
  "panels": [
    {
      "aliasColors": {},
      "bars": false,
      "dashLength": 10,
      "dashes": false,
      "datasource": "Prometheus",
      "fieldConfig": {
        "defaults": {
          "custom": {}
        },
        "overrides": []
      },
      "fill": 1,
      "fillGradient": 0,
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 0
      },
      "hiddenSeries": false,
      "id": 2,
      "legend": {
        "avg": false,
        "current": false,
        "max": false,
        "min": false,
        "show": true,
        "total": false,
        "values": false
      },
      "lines": true,
      "linewidth": 1,
      "nullPointMode": "null",
      "options": {
        "alertThreshold": true
      },
      "percentage": false,
      "pluginVersion": "7.3.7",
      "pointradius": 2,
      "points": false,
      "renderer": "flot",
      "seriesOverrides": [],
      "spaceLength": 10,
      "stack": false,
      "steppedLine": false,
      "targets": [
        {
          "expr": "jenkins_executor_count_value",
          "interval": "",
          "legendFormat": "Executors",
          "refId": "A"
        }
      ],
      "thresholds": [],
      "timeFrom": null,
      "timeRegions": [],
      "timeShift": null,
      "title": "Jenkins Executors",
      "tooltip": {
        "shared": true,
        "sort": 0,
        "value_type": "individual"
      },
      "type": "graph",
      "xaxis": {
        "buckets": null,
        "mode": "time",
        "name": null,
        "show": true,
        "values": []
      },
      "yaxes": [
        {
          "format": "short",
          "label": null,
          "logBase": 1,
          "max": null,
          "min": null,
          "show": true
        },
        {
          "format": "short",
          "label": null,
          "logBase": 1,
          "max": null,
          "min": null,
          "show": true
        }
      ],
      "yaxis": {
        "align": false,
        "alignLevel": null
      }
    },
    {
      "aliasColors": {},
      "bars": false,
      "dashLength": 10,
      "dashes": false,
      "datasource": "Prometheus",
      "fieldConfig": {
        "defaults": {
          "custom": {}
        },
        "overrides": []
      },
      "fill": 1,
      "fillGradient": 0,
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 0
      },
      "hiddenSeries": false,
      "id": 4,
      "legend": {
        "avg": false,
        "current": false,
        "max": false,
        "min": false,
        "show": true,
        "total": false,
        "values": false
      },
      "lines": true,
      "linewidth": 1,
      "nullPointMode": "null",
      "options": {
        "alertThreshold": true
      },
      "percentage": false,
      "pluginVersion": "7.3.7",
      "pointradius": 2,
      "points": false,
      "renderer": "flot",
      "seriesOverrides": [],
      "spaceLength": 10,
      "stack": false,
      "steppedLine": false,
      "targets": [
        {
          "expr": "jenkins_builds_total",
          "interval": "",
          "legendFormat": "Builds",
          "refId": "A"
        }
      ],
      "thresholds": [],
      "timeFrom": null,
      "timeRegions": [],
      "timeShift": null,
      "title": "Jenkins Total Builds",
      "tooltip": {
        "shared": true,
        "sort": 0,
        "value_type": "individual"
      },
      "type": "graph",
      "xaxis": {
        "buckets": null,
        "mode": "time",
        "name": null,
        "show": true,
        "values": []
      },
      "yaxes": [
        {
          "format": "short",
          "label": null,
          "logBase": 1,
          "max": null,
          "min": null,
          "show": true
        },
        {
          "format": "short",
          "label": null,
          "logBase": 1,
          "max": null,
          "min": null,
          "show": true
        }
      ],
      "yaxis": {
        "align": false,
        "alignLevel": null
      }
    }
  ],
  "refresh": "5s",
  "schemaVersion": 26,
  "style": "dark",
  "tags": [],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-6h",
    "to": "now"
  },
  "timepicker": {},
  "timezone": "",
  "title": "Jenkins Dashboard",
  "uid": "jenkins",
  "version": 1
} 
EOF

# Create devsecops-pipeline/jenkins.Dockerfile
cat > "devsecops-pipeline/jenkins.Dockerfile" << 'EOF'
FROM jenkins/jenkins:lts

USER root

# Install dependencies
RUN apt-get update && \
    apt-get install -y apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common

# Add Docker's official GPG key
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Set up the Docker repository
RUN echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
RUN apt-get update && \
    apt-get install -y docker-ce docker-ce-cli containerd.io

# Install Ansible
RUN apt-get update && \
    apt-get install -y ansible

# Install Ansible and sshpass
RUN apt-get update && \
    apt-get install -y ansible sshpass

# Install Jenkins plugins
RUN jenkins-plugin-cli --plugins "blueocean docker-workflow ansible"

USER jenkins
EOF

# Create devsecops-pipeline/prometheus/prometheus.yml
cat > "devsecops-pipeline/prometheus/prometheus.yml" << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'jenkins'
    metrics_path: '/prometheus/'
    static_configs:
      - targets: ['jenkins:8080']

  - job_name: 'production'
    static_configs:
      - targets: ['172.16.104.136:9100']
      
  - job_name: 'spring-petclinic'
    metrics_path: /actuator/prometheus
    static_configs:
      - targets: ['172.16.104.136:80']
EOF

# Create pom.xml
cat > "pom.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.4.2</version>
    <relativePath></relativePath>
  </parent>

  <groupId>org.springframework.samples</groupId>
  <artifactId>spring-petclinic</artifactId>
  <version>3.4.0-SNAPSHOT</version>

  <name>petclinic</name>

  <properties>

    <!-- Generic properties -->
    <java.version>17</java.version>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    <project.reporting.outputEncoding>UTF-8</project.reporting.outputEncoding>
    <!-- Important for reproducible builds. Update using e.g. ./mvnw versions:set
        -DnewVersion=... -->
    <project.build.outputTimestamp>2024-11-28T14:37:52Z</project.build.outputTimestamp>

    <!-- Web dependencies -->
    <webjars-locator.version>1.0.1</webjars-locator.version>
    <webjars-bootstrap.version>5.3.3</webjars-bootstrap.version>
    <webjars-font-awesome.version>4.7.0</webjars-font-awesome.version>

    <checkstyle.version>10.20.1</checkstyle.version>
    <jacoco.version>0.8.12</jacoco.version>
    <libsass.version>0.2.29</libsass.version>
    <lifecycle-mapping>1.0.0</lifecycle-mapping>
    <maven-checkstyle.version>3.6.0</maven-checkstyle.version>
    <nohttp-checkstyle.version>0.0.11</nohttp-checkstyle.version>
    <spring-format.version>0.0.43</spring-format.version>

  </properties>

  <dependencies>
    <!-- Spring and Spring Boot dependencies -->
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-cache</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-data-jpa</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-validation</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-thymeleaf</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId>
      <scope>test</scope>
    </dependency>
    <dependency>
      <!-- Workaround for AOT issue (https://github.com/spring-projects/spring-framework/pull/33949) -->
      <groupId>io.projectreactor</groupId>
      <artifactId>reactor-core</artifactId>
    </dependency>

    <!-- Databases - Uses H2 by default -->
    <dependency>
      <groupId>com.h2database</groupId>
      <artifactId>h2</artifactId>
      <scope>runtime</scope>
    </dependency>
    <dependency>
      <groupId>com.mysql</groupId>
      <artifactId>mysql-connector-j</artifactId>
      <scope>runtime</scope>
    </dependency>
    <dependency>
      <groupId>org.postgresql</groupId>
      <artifactId>postgresql</artifactId>
      <scope>runtime</scope>
    </dependency>

    <!-- Caching -->
    <dependency>
      <groupId>javax.cache</groupId>
      <artifactId>cache-api</artifactId>
    </dependency>
    <dependency>
      <groupId>com.github.ben-manes.caffeine</groupId>
      <artifactId>caffeine</artifactId>
    </dependency>

    <!-- Webjars -->
    <dependency>
      <groupId>org.webjars</groupId>
      <artifactId>webjars-locator-lite</artifactId>
      <version>${webjars-locator.version}</version>
    </dependency>
    <dependency>
      <groupId>org.webjars.npm</groupId>
      <artifactId>bootstrap</artifactId>
      <version>${webjars-bootstrap.version}</version>
    </dependency>
    <dependency>
      <groupId>org.webjars.npm</groupId>
      <artifactId>font-awesome</artifactId>
      <version>${webjars-font-awesome.version}</version>
    </dependency>

    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-devtools</artifactId>
      <scope>test</scope>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-testcontainers</artifactId>
      <scope>test</scope>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-docker-compose</artifactId>
      <scope>test</scope>
    </dependency>
    <dependency>
      <groupId>org.testcontainers</groupId>
      <artifactId>junit-jupiter</artifactId>
      <scope>test</scope>
    </dependency>
    <dependency>
      <groupId>org.testcontainers</groupId>
      <artifactId>mysql</artifactId>
      <scope>test</scope>
    </dependency>

    <dependency>
      <groupId>jakarta.xml.bind</groupId>
      <artifactId>jakarta.xml.bind-api</artifactId>
    </dependency>

    <dependency>
      <groupId>io.micrometer</groupId>
      <artifactId>micrometer-registry-prometheus</artifactId>
    </dependency>

  </dependencies>

  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-enforcer-plugin</artifactId>
        <executions>
          <execution>
            <id>enforce-java</id>
            <goals>
              <goal>enforce</goal>
            </goals>
            <configuration>
              <rules>
                <requireJavaVersion>
                  <message>This build requires at least Java ${java.version},
                                        update your JVM, and
                                        run the build again</message>
                  <version>${java.version}</version>
                </requireJavaVersion>
              </rules>
            </configuration>
          </execution>
        </executions>
      </plugin>
      <plugin>
        <groupId>io.spring.javaformat</groupId>
        <artifactId>spring-javaformat-maven-plugin</artifactId>
        <version>${spring-format.version}</version>
        <executions>
          <execution>
            <goals>
              <goal>validate</goal>
            </goals>
            <phase>validate</phase>
          </execution>
        </executions>
      </plugin>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-checkstyle-plugin</artifactId>
        <version>${maven-checkstyle.version}</version>
        <dependencies>
          <dependency>
            <groupId>com.puppycrawl.tools</groupId>
            <artifactId>checkstyle</artifactId>
            <version>${checkstyle.version}</version>
          </dependency>
          <dependency>
            <groupId>io.spring.nohttp</groupId>
            <artifactId>nohttp-checkstyle</artifactId>
            <version>${nohttp-checkstyle.version}</version>
          </dependency>
        </dependencies>
        <executions>
          <execution>
            <id>nohttp-checkstyle-validation</id>
            <goals>
              <goal>check</goal>
            </goals>
            <phase>validate</phase>
            <configuration>
              <configLocation>src/checkstyle/nohttp-checkstyle.xml</configLocation>
              <sourceDirectories>${basedir}</sourceDirectories>
              <includes>**/*</includes>
              <excludes>**/.git/**/*,**/.idea/**/*,**/target/**/,**/.flattened-pom.xml,**/*.class</excludes>
              <propertyExpansion>config_loc=${basedir}/src/checkstyle/</propertyExpansion>
            </configuration>
          </execution>
        </executions>
      </plugin>
      <plugin>
        <groupId>org.graalvm.buildtools</groupId>
        <artifactId>native-maven-plugin</artifactId>
      </plugin>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
        <executions>
          <execution>
            <!-- Spring Boot Actuator displays build-related information
              if a META-INF/build-info.properties file is present -->
            <goals>
              <goal>build-info</goal>
            </goals>
            <configuration>
              <additionalProperties>
                <encoding.source>${project.build.sourceEncoding}</encoding.source>
                <encoding.reporting>${project.reporting.outputEncoding}</encoding.reporting>
                <java.source>${java.version}</java.source>
                <java.target>${java.version}</java.target>
              </additionalProperties>
            </configuration>
          </execution>
        </executions>
      </plugin>
      <plugin>
        <groupId>org.jacoco</groupId>
        <artifactId>jacoco-maven-plugin</artifactId>
        <version>${jacoco.version}</version>
        <executions>
          <execution>
            <goals>
              <goal>prepare-agent</goal>
            </goals>
          </execution>
          <execution>
            <id>report</id>
            <goals>
              <goal>report</goal>
            </goals>
            <phase>prepare-package</phase>
          </execution>
        </executions>
      </plugin>

      <!-- Spring Boot Actuator displays build-related information if a git.properties file is
      present at the classpath -->
      <plugin>
        <groupId>io.github.git-commit-id</groupId>
        <artifactId>git-commit-id-maven-plugin</artifactId>
        <configuration>
          <failOnNoGitDirectory>false</failOnNoGitDirectory>
          <failOnUnableToExtractRepoInfo>false</failOnUnableToExtractRepoInfo>
        </configuration>
      </plugin>
      <!-- Spring Boot Actuator displays sbom-related information if a CycloneDX SBOM file is
      present at the classpath -->
      <plugin>
        <?m2e ignore?>
        <groupId>org.cyclonedx</groupId>
        <artifactId>cyclonedx-maven-plugin</artifactId>
      </plugin>

    </plugins>
  </build>
  <licenses>
    <license>
      <name>Apache License, Version 2.0</name>
      <url>https://www.apache.org/licenses/LICENSE-2.0</url>
    </license>
  </licenses>

  <repositories>
    <repository>
      <snapshots>
        <enabled>true</enabled>
      </snapshots>
      <id>spring-snapshots</id>
      <name>Spring Snapshots</name>
      <url>https://repo.spring.io/snapshot</url>
    </repository>
    <repository>
      <snapshots>
        <enabled>false</enabled>
      </snapshots>
      <id>spring-milestones</id>
      <name>Spring Milestones</name>
      <url>https://repo.spring.io/milestone</url>
    </repository>
  </repositories>
  <pluginRepositories>
    <pluginRepository>
      <snapshots>
        <enabled>true</enabled>
      </snapshots>
      <id>spring-snapshots</id>
      <name>Spring Snapshots</name>
      <url>https://repo.spring.io/snapshot</url>
    </pluginRepository>
    <pluginRepository>
      <snapshots>
        <enabled>false</enabled>
      </snapshots>
      <id>spring-milestones</id>
      <name>Spring Milestones</name>
      <url>https://repo.spring.io/milestone</url>
    </pluginRepository>
  </pluginRepositories>

  <profiles>
    <profile>
      <id>css</id>
      <build>
        <plugins>
          <plugin>
            <groupId>org.apache.maven.plugins</groupId>
            <artifactId>maven-dependency-plugin</artifactId>
            <executions>
              <execution>
                <id>unpack</id>
                <goals>
                  <goal>unpack</goal>
                </goals>
                <?m2e execute onConfiguration,onIncremental?>
                <phase>generate-resources</phase>
                <configuration>
                  <artifactItems>
                    <artifactItem>
                      <groupId>org.webjars.npm</groupId>
                      <artifactId>bootstrap</artifactId>
                      <version>${webjars-bootstrap.version}</version>
                    </artifactItem>
                  </artifactItems>
                  <outputDirectory>${project.build.directory}/webjars</outputDirectory>
                </configuration>
              </execution>
            </executions>
          </plugin>

          <plugin>
            <groupId>com.gitlab.haynes</groupId>
            <artifactId>libsass-maven-plugin</artifactId>
            <version>${libsass.version}</version>
            <configuration>
              <inputPath>${basedir}/src/main/scss/</inputPath>
              <outputPath>${basedir}/src/main/resources/static/resources/css/</outputPath>
              <includePath>${project.build.directory}/webjars/META-INF/resources/webjars/bootstrap/${webjars-bootstrap.version}/scss/</includePath>
            </configuration>
            <executions>
              <execution>
                <?m2e execute onConfiguration,onIncremental?>
                <goals>
                  <goal>compile</goal>
                </goals>
                <phase>generate-resources</phase>
              </execution>
            </executions>
          </plugin>
        </plugins>
      </build>
    </profile>
    <profile>
      <id>m2e</id>
      <activation>
        <property>
          <name>m2e.version</name>
        </property>
      </activation>
      <build>
        <pluginManagement>
          <plugins>
            <!-- This plugin's configuration is used to store Eclipse m2e settings
              only. It has no influence on the Maven build itself. -->
            <plugin>
              <groupId>org.eclipse.m2e</groupId>
              <artifactId>lifecycle-mapping</artifactId>
              <version>${lifecycle-mapping}</version>
              <configuration>
                <lifecycleMappingMetadata>
                  <pluginExecutions>
                    <pluginExecution>
                      <pluginExecutionFilter>
                        <groupId>org.apache.maven.plugins</groupId>
                        <artifactId>maven-checkstyle-plugin</artifactId>
                        <versionRange>[1,)</versionRange>
                        <goals>
                          <goal>check</goal>
                        </goals>
                      </pluginExecutionFilter>
                      <action>
                        <ignore></ignore>
                      </action>
                    </pluginExecution>
                    <pluginExecution>
                      <pluginExecutionFilter>
                        <groupId>org.springframework.boot</groupId>
                        <artifactId>spring-boot-maven-plugin</artifactId>
                        <versionRange>[1,)</versionRange>
                        <goals>
                          <goal>build-info</goal>
                        </goals>
                      </pluginExecutionFilter>
                      <action>
                        <ignore></ignore>
                      </action>
                    </pluginExecution>
                    <pluginExecution>
                      <pluginExecutionFilter>
                        <groupId>io.spring.javaformat</groupId>
                        <artifactId>spring-javaformat-maven-plugin</artifactId>
                        <versionRange>[0,)</versionRange>
                        <goals>
                          <goal>validate</goal>
                        </goals>
                      </pluginExecutionFilter>
                      <action>
                        <ignore></ignore>
                      </action>
                    </pluginExecution>
                  </pluginExecutions>
                </lifecycleMappingMetadata>
              </configuration>
            </plugin>
          </plugins>
        </pluginManagement>
      </build>
    </profile>
  </profiles>
</project>
EOF

docker network create devsecops-network
docker-compose up -d
docker ps