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


exports.GithubCommunicator = GithubCommunicator
     

class PullRequestCommenter extends GithubCommunicator

  BUILDREPORT_MARKER = "**Build Status**"
  IMAGE_PATH = "https://github.com/percolate/jennifer/raw/master/public/assets/images"
  PASSED_PATH = "#{IMAGE_PATH}/passed.png"
  FAILED_PATH = "#{IMAGE_PATH}/failed.png"

  constructor: (@sha, @job, @build, @user, @repo, @succeeded, @authToken) ->
    super @user, env.GITHUB_REPO, @authToken
    @job_url = "#{env.JENKINS_URL}/job/#{@job}/#{@build}"

  successComment: =>
    @makeBuildReport "Succeeded", PASSED_PATH

  errorComment: =>
    @makeBuildReport "Failed", FAILED_PATH

  makeBuildReport: (status, image_path) =>
    report = "#{BUILDREPORT_MARKER}: `#{status}` "
    report += "![stoplight](#{image_path} \"#{status}\") "
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
          log.warning "No head found for PR json!"
          log.warning pr_map
          return 

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
      old_comments = _.filter comments, ({ body }) -> _s.include body, BUILDREPORT_MARKER
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

   
exports.PullRequestCommenter = PullRequestCommenter

