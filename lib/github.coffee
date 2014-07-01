#
# Classes that manage GitHub API interaction
#

async   = require 'async'
request = require 'request'
_       = require 'underscore'
_s      = require 'underscore.string'

env     = require '../env'
log     = require('./logging').log


class GithubCommunicator
  constructor: (@user, @repo, @authToken) ->
    @api = "https://api.github.com/repos/#{@user}/#{@repo}"
    @headers = {'User-Agent': 'Node.js/0.8.9 (Jennifer, by Percolate)'}

  buildApiUri: (path) =>
    access_param = "?access_token=#{@authToken}"

    if (path.indexOf '?') != -1
      path = path.replace '?', "#{access_param}&"
    else
      path = path + "#{access_param}"

    return "#{@api}#{path}"

  post: (path, obj, cb) =>
    log.debug "Calling POST on #{@buildApiUri(path)}."
    request.post { uri: @buildApiUri(path), json: obj, headers: @headers }, (e, r, body) ->
      log.debug body
      cb e, body

  get: (path, cb) =>
    log.debug "Calling GET on #{@buildApiUri(path)}."
    request.get { uri: @buildApiUri(path), json: true, headers: @headers }, (e, r, body) ->
      log.debug body
      cb e, body

  del: (path, cb) =>
    log.debug "Calling DEL on #{@buildApiUri(path)}."
    request.del { uri: @buildApiUri(path), headers: @headers }, (e, r, body) ->
      cb e, body

  getCommentsForIssue: (issue, cb) =>
    @get "/issues/#{issue}/comments", cb

  deleteComment: (id, cb) =>
    @del "/issues/comments/#{id}", cb

  # XXX this will only return the first 100 pull requests. There's no quick
  # way to handle pagination beyond that.
  getPulls: (cb) =>
    @get "/pulls?per_page=100", cb

  getPull: (id, cb) =>
    @get "/pulls/#{id}", cb

  # XXX this will only return the first 100 pull requests. There's no quick
  # way to handle pagination beyond that.
  getOpenPulls: (cb) =>
    @get "/pulls?state=open&per_page=100", cb

  getOpenPullNumbersToBranches: (cb) =>
    @getOpenPulls (e, body) ->
      if e or (not body?)
        log.warn "Encountered error getting open PRs."
        log.warn e
        log.warn body
        return

      numToBranch = {}

      for pr in body
        numToBranch[pr.number] = pr.head.ref

      cb(e, numToBranch)

  commentOnIssue: (issue, comment) =>
    @post "/issues/#{issue}/comments", (body: comment), (e, body) ->
      log.info "Posting comment '#{comment}'."
      log.warn e if e?

  setCommitStatus: (sha, state, target, description) =>
    @post "/statuses/#{sha}", ({state: state, target_url: target, description: description}), (e, body) ->
      log.info "Updating commit status to '#{state}' for #{target}"
      log.warn e if e?


exports.GithubCommunicator = GithubCommunicator


class PullRequestCommenter extends GithubCommunicator

  BUILDREPORT_MARKER = "**Build Status**"
  EMOJI = {"Failed":":thumbsdown:","Succeeded":":thumbsup:","Pending":":hand:"}

  constructor: (@sha, @job, @build, @user, @repo, @succeeded, @authToken) ->
    super @user, env.GITHUB_REPO, @authToken
    @job_url = "#{env.JENKINS_URL}/job/#{@job}/#{@build}"

  errorComment: =>
    @makeBuildReport "Failed"

  makeBuildReport: (status) =>
    report = "#{BUILDREPORT_MARKER}: `#{status}` "
    report += "#{EMOJI[status]}"
    report += " (#{@sha}, [build info](#{@job_url}))"

    report

  # Find the first open pull with a matching HEAD sha
  findMatchingPull: (pulls, cb) =>
    if !pulls?
      log.warn "Couldn't get pull requests."
      return

    pulls = _.filter pulls, (p) => p.state is 'open'
    async.detect pulls, (pull, detect_if) =>
      @getPull pull.number, (e, pr_map) =>
        if 'head' of pr_map
          head = pr_map.head
        else
          log.warn "No head found for PR json!"
          log.warn pr_map
          return

        log.debug "Checking PR number #{pull.number}."
        return cb e if e?
        log.debug "  HEAD of PR is #{head.sha}."
        detect_if head.sha is @sha
    , (match) =>
      return cb "No pull request for #{@sha} found" unless match?
      cb null, match

  updateCommitStatus: (pull, cb) =>
    status = switch @state
      when 'success' then 'success'
      when 'pending' then 'pending'
      else 'failure'
    comment = switch @state
      when 'success' then 'passed'
      when 'pending' then 'in progress'
      else 'failed'
    now = new Date()
    comment = "The Jenkins build " + comment + " on #{now.toString()}"
    @setCommitStatus @sha, status, @job_url, comment
    cb null, pull

  removePreviousPullComments: (pull, cb) =>
    @getCommentsForIssue pull.number, (e, comments) =>
      return cb e if e?
      old_comments = _.filter comments, ({ body }) -> _s.include body, BUILDREPORT_MARKER
      async.forEach old_comments, (comment, done_delete) =>
        @deleteComment comment.id, done_delete
      , () -> cb null, pull

  updateComments: (cb) =>
    async.waterfall [
      @getPulls
      @findMatchingPull
      @removePreviousPullComments
      @updateCommitStatus
    ], cb


exports.PullRequestCommenter = PullRequestCommenter
