module.exports = function (config) {
    config.set({
        basePath: '',
        frameworks: ['jasmine', '@angular-devkit/build-angular'],
        plugins: [
            require('karma-jasmine'),
            require('karma-chrome-launcher'),
            require('karma-jasmine-html-reporter'),
            require('karma-coverage'),
            require('@angular-devkit/build-angular/plugins/karma'),
            require('karma-sabarivka-reporter')
        ],
        client: {
            jasmine: {}
        },
        jasmineHtmlReporter: {
            suppressAll: true
        },
        coverageReporter: {
            dir: require('path').join(__dirname, './coverage'),
            subdir: '.',
            reporters: [{ type: 'html' }, { type: 'text-summary' }],
            include: 'src/**/!(*.spec).ts',
            exclude: 'src/main.ts',
            type: 'text',
            file: 'coverage.txt'
        },
        reporters: ['sabarivka', 'progress', 'kjhtml', 'coverage'],
        browsers: ['Chrome'],
        restartOnFileChange: true
    });
};
