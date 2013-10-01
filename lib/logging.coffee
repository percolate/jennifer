#
# set up logging
#

env = require '../env'

log4js = require('log4js')
log4js.configure
    appenders: [
        # { type: 'console' }
        { type: 'file', filename: env.LOG_FILE, category: 'app' }
    ]

log = log4js.getLogger 'app'
log.setLevel env.LOG_LEVEL

exports.log = log
         
