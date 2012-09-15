async   = require 'async'
request = require 'request'
express = require 'express'
_       = require 'underscore'
_s      = require 'underscore.string'
jenkinsapi = require 'jenkins-api'
cronJob = require('cron').CronJob

log4js = require('log4js')
log4js.configure
    appenders: [
        # { type: 'console' }
        { type: 'file', filename: 'jennifer.log', category: 'app' }
    ]

log = log4js.getLogger 'app'
log.setLevel 'DEBUG'

# All constants in this block must be defined as env variables
#
JENKINS_URL = process.env.JENKINS_URL
JENKINS_USERNAME = process.env.JENKINS_USERNAME
JENKINS_PASSWORD = process.env.JENKINS_PASSWORD
JENKINS_TEMPLATE_JOB_NAME = process.env.JENKINS_TEMPLATE_JOB_NAME
JENKINS_REMOTE_BUILD_AUTH_TOKEN = process.env.JENKINS_REMOTE_BUILD_AUTH_TOKEN
GITHUB_REPO_OWNER = process.env.GITHUB_REPO_OWNER
GITHUB_REPO = process.env.GITHUB_REPO
GITHUB_OAUTH_TOKEN = process.env.GITHUB_OAUTH_TOKEN
#
 
JENKINS_AUTHED_URL = JENKINS_URL.replace(
  /\/\//, "//#{JENKINS_USERNAME}:#{JENKINS_PASSWORD}@")
           

class GithubCommunicator
  constructor: (@user, @repo, @authToken) ->
    @api = "https://api.github.com/repos/#{@user}/#{@repo}"
  
  buildApiUri: (path) =>
    access_param = "?access_token=#{@authToken}"
    
    if (path.indexOf '?') != -1
      path = path.replace '?', "#{access_param}&"
    else
      path = path + "#{access_param}"

    return "#{@api}#{path}"

  post: (path, obj, cb) =>
    log.debug "Calling POST on #{@buildApiUri(path)}."
    request.post { uri: @buildApiUri(path), json: obj }, (e, r, body) ->
      log.debug body
      cb e, body

  get: (path, cb) =>
    log.debug "Calling GET on #{@buildApiUri(path)}."
    request.get { uri: @buildApiUri(path), json: true }, (e, r, body) ->
      log.debug body
      cb e, body
            
  del: (path, cb) =>
    log.debug "Calling DEL on #{@buildApiUri(path)}."
    request.del { uri: @buildApiUri(path) }, (e, r, body) ->
      cb e, body

  getCommentsForIssue: (issue, cb) =>
    @get "/issues/#{issue}/comments", cb

  deleteComment: (id, cb) =>
    @del "/issues/comments/#{id}", cb

  getPulls: (cb) =>
    @get "/pulls", cb
            
  getPull: (id, cb) =>
    @get "/pulls/#{id}", cb
       
  getOpenPulls: (cb) =>
    @get "/pulls?state=open", cb
                             
  getOpenPullNumbersToBranches: (cb) =>
    @getOpenPulls (e, body) ->
      if e
        log.warn "Encountered error getting open PRs."
        log.warn e
        return

      numToBranch = {}

      for pr in body
        numToBranch[pr.number] = pr.head.ref

      cb(e, numToBranch)

  commentOnIssue: (issue, comment) =>
    @post "/issues/#{issue}/comments", (body: comment), (e, body) ->
      log.info "Posting comment '#{comment}'."
      log.warn e if e?
     

class PullRequestCommenter extends GithubCommunicator
  BUILDREPORT = "**Build Status**:"

  constructor: (@sha, @job, @build, @user, @repo, @succeeded, @authToken) ->
    super @user, GITHUB_REPO, @authToken
    @job_url = "#{JENKINS_URL}/job/percolate/#{@job}"

  successComment: =>
    "#{BUILDREPORT} `Succeeded` (#{@sha}, [Jenkins job info](#{@job_url}))"

  errorComment: =>
    "#{BUILDREPORT} `Failed` (#{@sha}, [job info](#{@job_url}))"

  # Find the first open pull with a matching HEAD sha
  findMatchingPull: (pulls, cb) =>
    pulls = _.filter pulls, (p) => p.state is 'open'
    async.detect pulls, (pull, detect_if) =>
      @getPull pull.number, (e, { head }) =>
        log.debug "Checking PR number #{pull.number}."
        return cb e if e?
        log.debug "  HEAD of PR is #{head.sha}."
        detect_if head.sha is @sha
    , (match) =>
      return cb "No pull request for #{@sha} found" unless match?
      cb null, match

  removePreviousPullComments: (pull, cb) =>
    @getCommentsForIssue pull.number, (e, comments) =>
      return cb e if e?
      old_comments = _.filter comments, ({ body }) -> _s.include body, BUILDREPORT
      async.forEach old_comments, (comment, done_delete) =>
        @deleteComment comment.id, done_delete
      , () -> cb null, pull

  makePullComment: (pull, cb) =>
    comment = if @succeeded then @successComment() else @errorComment()
    @commentOnIssue pull.number, comment
    cb()

  updateComments: (cb) =>
    async.waterfall [
      @getPulls
      @findMatchingPull
      @removePreviousPullComments
      @makePullComment
    ], cb


class GithubPrJenkinsIntegrator

  constructor: (@ghCommunicator) ->
    @jenkins = jenkinsapi.init(JENKINS_AUTHED_URL)

  # sync PRs and Jenkins. Should be run periodically.
  #
  sync: () =>
      log.info "Syncing Github and Jenkins."
      async.series [
        @pruneJobs
        @syncJobs
      ]

  # get all job data from Jenkins
  #
  withJobData: (cb) =>
    @jenkins.all_jobs (err, data) ->
      if err
        log.warn "Got an error getting Jenkins job data."
        log.warn err

      log.debug "Got #{data.length} jobs from Jenkins."
      cb(data)
  
  # run a callback, being passed `numToBranch` for PRs and `jobData` for 
  # Jenkins jobs
  #
  withPrsAndJobs: (cb) =>
    @ghCommunicator.getOpenPullNumbersToBranches (e, numToBranch) =>
      if e
        log.warn "Got an error getting pull request data."
        log.warn e

        numPrs = (k for k of numToBranch).length
        log.debug "Got #{numPrs} PRs from github."

      @withJobData (jobData) ->
        cb(numToBranch, jobData)
        
  # delete any jenkins job without a corresponding PR
  #
  pruneJobs: (cb) =>
    log.info "Pruning old PR jobs."

    @withPrsAndJobs (numToBranch, jobData) =>
      jobNames = jobData.map (job) -> job.name
      branches = (branch for num, branch of numToBranch)

      for job in jobData
        if @isPrJob(job.name) and (@makeBranchFromJob(job.name) not in branches)
          log.info "Deleting old PR job #{job.name}."
          @deleteJob job.name

    log.info "Finished pruning jobs."
    cb(null)
         
  # for each PR in the GitHub repo, ensure a Jenkins job exists or create one
  #
  syncJobs: (cb) =>
    log.info "Syncing jobs to PRs."

    @withPrsAndJobs (numToBranch, jobData) =>
      if jobData
        branchesWithJobs = jobData.map (job) => @makeBranchFromJob(job.name)
      else
        branchesWithJobs = []

      for num, branch of numToBranch
        if branch not in branchesWithJobs
          log.debug "Creating branch #{branch}."
          @createJob branch, num

    log.info "Finished job creation."
    cb(null)

  # given a Jenkins job name, delete it
  #
  deleteJob: (jobName) =>
    @jenkins.delete_job jobName, (err, data) ->
      if err
        log.warn "Trouble deleting job #{jobName}."
        log.warn e

      log.info "Deleted job #{jobName}."

  # remove all PR-related jobs
  #
  deleteAllJobs: =>
    @withPrsAndJobs (_, jobData) =>
      for job in jobData
        if @isPrJob(job.name)
          @deleteJob(job.name)

  # determine if a Job was created from a PR by us based on its name
  #
  isPrJob: (jobName) =>
      return (jobName.indexOf "pr_") == 0

  # create a Job name based on a branch name
  #
  makePrJobName: (branchName, prNum) =>
      return "pr_#{prNum}_#{branchName}"

  makeBranchFromJob: (jobName) =>
      return jobName.replace /pr_\d+_/, ''

  # create a Jenkins job based on a PR
  # 
  createJob: (branchName, prNum) =>
    jobName = @makePrJobName(branchName, prNum)
    @jenkins.copy_job(
      JENKINS_TEMPLATE_JOB_NAME
      , jobName
      , (config) ->
        return config.replace '${pr_branch}', branchName
      , (err, data) =>
        if err
          log.warn "Trouble creating job for branch #{branchName}."
          log.warn err

        log.info "Created job for branch #{branchName}, PR #{prNum}."

        trigger_build_cb = =>
          @triggerBuild jobName, (e, body) ->
            if e
              log.warn "Failed to trigger build for #{jobName}."
              log.warn e

        setTimeout trigger_build_cb, 10000
    )

  triggerBuild: (jobName, cb) =>
    log.info "Triggering build on job #{jobName}."

    path ="#{JENKINS_AUTHED_URL}/job/#{jobName}/build"
    path += "?token=#{JENKINS_REMOTE_BUILD_AUTH_TOKEN}"

    request.get { uri: path, json: true }, (e, r, body) ->
      cb e, body

                
app = module.exports = express.createServer()

app.configure 'development', ->
  app.set "port", 3000
  log.info "Running on port 3000."

app.configure 'production', ->
  app.use express.errorHandler()
  app.set "port", 3000
  log.info "Running on port 3000."

app.get '/jenkins/jobs', (req, res) ->
  jenkins = jenkinsapi.init(JENKINS_AUTHED_URL)

  jenkins.all_jobs (err, data) ->
    if err
      return (console.log err)

    console.log data
    res.send 'Ok', 200

  jenkins.get_config_xml 'percolate', (err, data) ->
    console.log data

app.del '/jenkins/jobs', (req, res) ->
  ghComm = new GithubCommunicator(
    GITHUB_REPO_OWNER, GITHUB_REPO, GITHUB_OAUTH_TOKEN)
  ghJenkinsInt = new GithubPrJenkinsIntegrator ghComm
  ghJenkinsInt.deleteAllJobs()

  res.send 'Ok', 200

# Jenkins lets us know when a build has failed or succeeded.
app.get '/jenkins/post_build', (req, res) ->
  sha = req.param 'sha'
  job = req.param 'job'
  build = parseInt req.param 'build'
  sha = req.param 'sha'
  user = req.param 'user'
  repo = req.param 'repo'
  succeeded = req.param('status') is 'success'

  # Look for an open pull request with this SHA and make comments.
  commenter = new PullRequestCommenter(
    sha, job, build, user, repo, succeeded, GITHUB_OAUTH_TOKEN)

  commenter.updateComments (e, r) -> console.log e if e?
  res.send 'Ok', 200
  
ghComm = new GithubCommunicator(
  GITHUB_REPO_OWNER, GITHUB_REPO, GITHUB_OAUTH_TOKEN)

ghJenkinsInt = new GithubPrJenkinsIntegrator ghComm
ghJenkinsInt.sync()

new cronJob('0 */2 * * * *'
  , () ->
    ghJenkinsInt.sync()
  , null, true)
                                  
app.listen app.settings.port
 
