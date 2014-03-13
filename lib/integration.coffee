#
# Classes that handle Jenkins/GitHub integration
#

async      = require 'async'
request    = require 'request'
_          = require 'underscore'
_s         = require 'underscore.string'
jenkinsapi = require 'jenkins-api'

env     = require '../env'
log     = require('./logging').log

class GithubPrJenkinsIntegrator

  constructor: (@ghCommunicator) ->
    @jenkins = jenkinsapi.init(env.JENKINS_AUTHED_URL)

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

      if data?
        log.debug "Got #{data.length} jobs from Jenkins."
        cb(data)
      else
        log.warn "Got no data from Jenkins!"
        log.warn data

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

      if branches.length == 0
        log.info "Looks like there was no response from GH. skipping."
        return

      for job in jobData
        if @isPrJob(job.name) and (@makeBranchFromJob(job.name) not in branches)
          log.info "Deleting old PR job #{job.name}."
          @deleteJob job.name

    log.debug "Finished pruning jobs."
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

    log.debug "Finished job creation."
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
      return "pr_#{prNum}_#{ encodeURIComponent branchName }"

  makeBranchFromJob: (jobName) =>
      return decodeURIComponent jobName.replace /pr_\d+_/, ''

  # create a Jenkins job based on a PR
  #
  createJob: (branchName, prNum) =>
    jobName = @makePrJobName(branchName, prNum)

    @jenkins.copy_job(
      env.JENKINS_TEMPLATE_JOB_NAME
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

        setTimeout trigger_build_cb, (30 * 1000)
    )

  triggerBuild: (jobName, cb) =>
    log.info "Triggering build on job #{jobName}."

    path ="#{env.JENKINS_AUTHED_URL}/job/#{jobName}/build"
    path += "?token=#{env.JENKINS_REMOTE_BUILD_AUTH_TOKEN}"

    log.info "Hitting path #{path}."

    request.get { uri: path }, (e, r, body) ->
      cb e, body


exports.GithubPrJenkinsIntegrator = GithubPrJenkinsIntegrator
