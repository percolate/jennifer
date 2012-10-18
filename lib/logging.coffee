#
# set up logging
#

log4js = require('log4js')
log4js.configure
    appenders: [
        # { type: 'console' }
        { type: 'file', filename: 'jennifer.log', category: 'app' }
    ]

log = log4js.getLogger 'app'
log.setLevel 'INFO'

exports.log = log
         
