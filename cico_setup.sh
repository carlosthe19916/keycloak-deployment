#!/bin/bash
# Output command before executing
set -x

# Exit on error
set -e

REPO_NAME="fabric8-services"
CURRENT_DIR=$(pwd)
PROJECT_NAME="keycloak"
DOCKER_IMAGE_CORE=$PROJECT_NAME
DOCKER_IMAGE_DEPLOY=$PROJECT_NAME-deploy

KEYCLOAK_VERSION="3.4.3.Final"
BRANCH_NAME="3.4.3.Final-patch"

# Source environment variables of the jenkins slave
# that might interest this worker.
function load_jenkins_vars() {
  if [ -e "jenkins-env" ]; then
    cat jenkins-env \
      | grep -E "(DEVSHIFT_TAG_LEN|DEVSHIFT_USERNAME|DEVSHIFT_PASSWORD|JENKINS_URL|GIT_BRANCH|GIT_COMMIT|BUILD_NUMBER|ghprbSourceBranch|ghprbActualCommit|BUILD_URL|ghprbPullId)=" \
      | sed 's/^/export /g' \
      > ~/.jenkins-env
    source ~/.jenkins-env
  fi
}

function install_deps() {
  # We need to disable selinux for now, XXX
  /usr/sbin/setenforce 0 || :

  # Get all the deps in
  yum -y install \
    docker \
    make \
    git \
    wget \
    curl

  wget http://repos.fedorapeople.org/repos/dchen/apache-maven/epel-apache-maven.repo -O /etc/yum.repos.d/epel-apache-maven.repo
  yum -y install apache-maven

  service docker start
  echo 'CICO: Dependencies installed'
}

function build() {
  echo 'CICO: Cloning keycloak source code repo'
  [ ! -d keycloak ] && git clone -b $BRANCH_NAME  --depth 1 https://github.com/fabric8-services/keycloak.git

  cd keycloak
  # Set the version according to the ENV variable
  #mvn -q versions:set -DgenerateBackupPoms=false -DnewVersion=$KEYCLOAK_VERSION
  # Only build the keycloak-server to save time
  #echo 'CICO: Installing without specifying a version'
  #mvn clean install -DskipTests=true -pl :keycloak-server-dist -am -P distribution
  echo 'CICO: Run mv clean install -DskipTests=true -Pdistribution'
  mvn clean install -DskipTests=true -Pdistribution

  echo 'CICO: Listing the directory server-dist'
  ls distribution/server-dist/
  echo 'CICO: Listing the directory target'
  ls distribution/server-dist/target

  cd ..

  echo 'CICO: keycloak-server build completed successfully!'
}

function tag_push() {
  local tag=$1
  docker tag $DOCKER_IMAGE_DEPLOY $tag
  docker push $tag
}

function deploy() {
  cp keycloak/distribution/server-dist/target/keycloak-$KEYCLOAK_VERSION.tar.gz docker

  TAG=$(echo $GIT_COMMIT | cut -c1-${DEVSHIFT_TAG_LEN})
  REGISTRY="push.registry.devshift.net"

  if [ -n "${DEVSHIFT_USERNAME}" -a -n "${DEVSHIFT_PASSWORD}" ]; then
    docker login -u ${DEVSHIFT_USERNAME} -p ${DEVSHIFT_PASSWORD} ${REGISTRY}
  else
    echo "Could not login, missing credentials for the registry"
  fi

  if [ "$TARGET" = "rhel" ]; then
    DOCKERFILE="Dockerfile.rhel"
  else
    DOCKERFILE="Dockerfile"
  fi

  # Let's deploy
  docker build -t $DOCKER_IMAGE_DEPLOY -f $CURRENT_DIR/docker/${DOCKERFILE} $CURRENT_DIR/docker

  rm docker/keycloak-$KEYCLOAK_VERSION.tar.gz

  if [ "$TARGET" = "rhel" ]; then
    tag_push ${REGISTRY}/osio-prod/${REPO_NAME}/${PROJECT_NAME}-postgres:$TAG
    tag_push ${REGISTRY}/osio-prod/${REPO_NAME}/${PROJECT_NAME}-postgres:latest
  else
    tag_push ${REGISTRY}/${REPO_NAME}/${PROJECT_NAME}-postgres:$TAG
    tag_push ${REGISTRY}/${REPO_NAME}/${PROJECT_NAME}-postgres:latest
  fi
  echo 'CICO: Image pushed, ready to update deployed app'
}

function cico_setup() {
  load_jenkins_vars;
  install_deps;
  build;
}
