pipeline {
    agent any
    stages {
        stage('Build Docker Image') {
            steps {
                sh 'docker build -t my-simple-app:latest ./java'
                sh 'docker images | grep my-simple-app'
            }
        }
        stage('Run App') {
            steps {
                sh 'docker rm -f my-simple-app || true'
                sh 'docker run -d --name my-simple-app -p 8090:8090 my-simple-app:latest'
            }
        }
    }
}