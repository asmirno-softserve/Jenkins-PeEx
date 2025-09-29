pipeline {
    agent any
    environment {
        VERSION_FILE = "VERSION.txt"
        AWS_REGION   = "eu-central-1"
        ECR_REPO     = "my-simple-app"
    }
    stages {
        stage('Prepare Version') {
            steps {
                sh '''
                    pip install --user semver
                    if [ ! -f $VERSION_FILE ]; then
                        echo "0.1.0" > $VERSION_FILE
                    fi
                    NEW_VERSION=$(semver bump patch $(cat $VERSION_FILE))
                    echo $NEW_VERSION > $VERSION_FILE
                    echo "Building version $NEW_VERSION"
                '''
            }
        }

        stage('Build Docker Image') {
            steps {
                sh '''
                    VERSION=$(cat $VERSION_FILE)
                    docker build -t $ECR_REPO:$VERSION ./java
                    docker tag $ECR_REPO:$VERSION $ECR_REPO:latest
                '''
            }
        }

        stage('Push to ECR') {
            steps {
                sh '''
                    VERSION=$(cat $VERSION_FILE)

                    # Authenticate Docker to ECR
                    aws ecr get-login-password --region $AWS_REGION | \
                      docker login --username AWS --password-stdin $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com

                    # Tag for ECR
                    docker tag $ECR_REPO:$VERSION $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:$VERSION
                    docker tag $ECR_REPO:$VERSION $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest

                    # Push to ECR
                    docker push $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:$VERSION
                    docker push $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest
                '''
            }
        }
    }
}
