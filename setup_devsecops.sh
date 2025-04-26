#!/bin/bash

set -e

# 1. Create docker network
docker network create devsecops-network || echo "Network already exists"

# 2. Start Docker containers
cd spring-petclinic/devsecops-pipeline
docker compose up -d --build
cd ../../

# 3. Wait for Jenkins to be ready
echo "[*] Waiting for Jenkins to come up..."
sleep 60

# 4. Download Jenkins CLI
JENKINS_URL=http://localhost:8080
JENKINS_CLI=jenkins-cli.jar

curl -o $JENKINS_CLI $JENKINS_URL/jnlpJars/jenkins-cli.jar

# 5. Unlock Jenkins (assuming you retrieved initial password manually once)

echo "[*] Installing plugins (Blue Ocean, Docker, SonarQube Scanner, Prometheus Metrics)..."
java -jar $JENKINS_CLI -s $JENKINS_URL install-plugin blueocean docker-workflow sonar docker-plugin ansible workflow-aggregator prometheus

# 6. Restart Jenkins to apply plugins
java -jar $JENKINS_CLI -s $JENKINS_URL safe-restart

echo "[*] Waiting for Jenkins restart..."
sleep 60

# 7. Create Jenkins job (pipeline)
echo "[*] Creating Jenkins pipeline job automatically..."
cat <<EOF > spring-petclinic-job.xml
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Spring PetClinic DevSecOps Pipeline</description>
  <keepDependencies>false</keepDependencies>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>https://github.com/teyenc/spring-petclinic.git</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
    </scm>
    <scriptPath>Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
</flow-definition>
EOF

# Create Job
java -jar $JENKINS_CLI -s $JENKINS_URL create-job spring-petclinic < spring-petclinic-job.xml

# 8. Trigger initial build
echo "[*] Triggering initial build..."
java -jar $JENKINS_CLI -s $JENKINS_URL build spring-petclinic

# 9. Wait for pipeline to build and trigger Ansible
sleep 120

# 10. Verify deployment
echo "[*] Deployment should be available at your VM's public IP!"

echo "[✅] Setup complete."
