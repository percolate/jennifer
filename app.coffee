#
# Contains routes and polling jobs
#

request    = require 'request'
express    = require 'express'
jenkinsapi = require 'jenkins-api'
cronJob    = require('cron').CronJob

env          = require './env'
github       = require './lib/github'
integration  = require './lib/integration'
log          = require('./lib/logging').log


app = module.exports = express.createServer()


app.configure 'development', ->
  app.set "port", 3000
  log.info "Running on port 3000."


app.configure 'production', ->
  app.use express.errorHandler()
  app.set "port", 3000
  log.info "Running on port 3000."


# GET a list of jenkins jobs
#
app.get '/jenkins/jobs', (req, res) ->
  jenkins = jenkinsapi.init(env.JENKINS_AUTHED_URL)

  jenkins.all_jobs (err, data) ->
    if err
      return (console.log err)

    console.log data
    res.send 'Ok', 200

  jenkins.get_config_xml 'percolate', (err, data) ->
    console.log data


# Delete a particular jenkins job
#
app.del '/jenkins/jobs', (req, res) ->
  ghComm = new github.GithubCommunicator(
    env.GITHUB_REPO_OWNER, env.GITHUB_REPO, env.GITHUB_OAUTH_TOKEN)
  ghJenkinsInt = new integration.GithubPrJenkinsIntegrator ghComm
  ghJenkinsInt.deleteAllJobs()

  res.send 'Ok', 200

# Jenkins lets us know when it he starts a build
#
app.get '/jenkins/build_pending', (req, res) ->
  sha = req.param 'sha'
  job = req.param 'job'
  build = parseInt req.param 'build'
  user = req.param 'user'
  repo = req.param 'repo'
  pending = req.param('status') is 'pending'

  # Look for an open pull request with this SHA and make comments.
  commenter = new github.PullRequestCommenter(
    sha, job, build, user, repo, pending, env.GITHUB_OAUTH_TOKEN)

  commenter.updateComments (e, r) -> console.log e if e?
  res.send 'Ok', 200

# Jenkins lets us know when a build has failed or succeeded
#
app.get '/jenkins/post_build', (req, res) ->
  sha = req.param 'sha'
  job = req.param 'job'
  build = parseInt req.param 'build'
  user = req.param 'user'
  repo = req.param 'repo'
  succeeded = req.param('status') is 'success'

  # Look for an open pull request with this SHA and make comments.
  commenter = new github.PullRequestCommenter(
    sha, job, build, user, repo, succeeded, env.GITHUB_OAUTH_TOKEN)

  commenter.updateComments (e, r) -> console.log e if e?
  res.send 'Ok', 200


# Poll periodicially for new PRs, respond accordingly
#
start_polling = ->
  ghComm = new github.GithubCommunicator(
    env.GITHUB_REPO_OWNER, env.GITHUB_REPO, env.GITHUB_OAUTH_TOKEN)

  ghJenkinsInt = new integration.GithubPrJenkinsIntegrator ghComm
  ghJenkinsInt.sync()

  new cronJob('0 */2 * * * *'
    , () ->
      ghJenkinsInt.sync()
    , null, true)


app.listen app.settings.port
start_polling()
