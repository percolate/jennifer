
# All constants in this block must be defined as env variables
#
exports.LOG_FILE = process.env.LOG_FILE || 'jennifer.log'
exports.LOG_LEVEL = process.env.LOG_LEVEL || 'INFO'
exports.JENKINS_URL = process.env.JENKINS_URL
exports.JENKINS_USERNAME = process.env.JENKINS_USERNAME
exports.JENKINS_PASSWORD = process.env.JENKINS_PASSWORD
exports.JENKINS_TEMPLATE_JOB_NAME = process.env.JENKINS_TEMPLATE_JOB_NAME
exports.JENKINS_REMOTE_BUILD_AUTH_TOKEN = process.env.JENKINS_REMOTE_BUILD_AUTH_TOKEN
exports.GITHUB_REPO_OWNER = process.env.GITHUB_REPO_OWNER
exports.GITHUB_REPO = process.env.GITHUB_REPO
exports.GITHUB_OAUTH_TOKEN = process.env.GITHUB_OAUTH_TOKEN
#

exports.JENKINS_AUTHED_URL = exports.JENKINS_URL.replace(
  /\/\//, "//#{exports.JENKINS_USERNAME}:#{exports.JENKINS_PASSWORD}@")
