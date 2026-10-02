using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

namespace FabricCapacityOverage.Tests
{
    public sealed class HttpException : Exception
    {
        public object Response { get; private set; }
        public HttpException(int status, object headers) : base("Offline HTTP fixture")
        {
            Response = new HttpResponse { StatusCode = status, Headers = headers };
        }
    }

    public sealed class HttpResponse
    {
        public int StatusCode { get; set; }
        public object Headers { get; set; }
    }

    public sealed class ConfirmationHost : PSHost
    {
        private readonly Guid id = Guid.NewGuid();
        private readonly ConfirmationUI ui = new ConfirmationUI();
        public int PromptCount { get { return ui.PromptCount; } }
        public override Guid InstanceId { get { return id; } }
        public override string Name { get { return "Offline decline-confirmation fixture"; } }
        public override Version Version { get { return new Version(1, 0); } }
        public override PSHostUserInterface UI { get { return ui; } }
        public override CultureInfo CurrentCulture { get { return CultureInfo.InvariantCulture; } }
        public override CultureInfo CurrentUICulture { get { return CultureInfo.InvariantCulture; } }
        public override void EnterNestedPrompt() { throw new NotSupportedException(); }
        public override void ExitNestedPrompt() { throw new NotSupportedException(); }
        public override void NotifyBeginApplication() { }
        public override void NotifyEndApplication() { }
        public override void SetShouldExit(int exitCode) { }
    }

    public sealed class ConfirmationUI : PSHostUserInterface
    {
        public int PromptCount { get; private set; }
        public override PSHostRawUserInterface RawUI { get { return null; } }
        public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
        {
            PromptCount++;
            for (int i = 0; i < choices.Count; i++)
                if (choices[i].Label.Replace("&", "") == "No") return i;
            throw new InvalidOperationException("No explicit decline choice was offered.");
        }
        public override string ReadLine() { throw new NotSupportedException(); }
        public override SecureString ReadLineAsSecureString() { throw new NotSupportedException(); }
        public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions)
        { throw new NotSupportedException(); }
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName)
        { throw new NotSupportedException(); }
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName,
            PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options)
        { throw new NotSupportedException(); }
        public override void Write(string value) { }
        public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value) { }
        public override void WriteLine(string value) { }
        public override void WriteErrorLine(string value) { }
        public override void WriteDebugLine(string message) { }
        public override void WriteProgress(long sourceId, ProgressRecord record) { }
        public override void WriteVerboseLine(string message) { }
        public override void WriteWarningLine(string message) { }
    }
}
