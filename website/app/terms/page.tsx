import { DraftNotice } from "@/components/DraftNotice";
import { FeedbackWarning } from "@/components/FeedbackWarning";
import { PageShell } from "@/components/PageShell";

const sections = [
  {
    title: "Use of Supra AI",
    body: "Supra AI is intended for use by legal professionals to assist with research, drafting, and document analysis. You are responsible for using it in compliance with applicable law and the rules of professional conduct in your jurisdiction.",
  },
  {
    title: "Public beta status",
    body: "Supra AI is provided as a public beta. Features may change, break, or be removed, and availability is not guaranteed. Beta releases are offered for evaluation and feedback.",
  },
  {
    title: "No legal advice",
    body: "Supra AI does not provide legal advice and is not a law firm. Its outputs are tools to support an attorney’s independent judgment, not a substitute for it.",
  },
  {
    title: "No attorney-client relationship",
    body: "Use of the software does not create an attorney-client relationship with Supra AI, Cade Spivey, or any contributor.",
  },
  {
    title: "User responsibility for verification",
    body: "You are solely responsible for reviewing, verifying, and correcting all outputs — including citations, quotations, and analysis — before using them. Do not rely on outputs without independent verification.",
  },
  {
    title: "Software availability and changes",
    body: "We may modify, suspend, or discontinue any part of the software at any time during the beta, without notice. We are not obligated to provide updates, support, or backward compatibility.",
  },
  {
    title: "Feedback submissions",
    body: "Feedback you submit through public channels is public. Do not include confidential or privileged information. By submitting feedback, you allow it to be used to improve the software.",
  },
  {
    title: "No warranty",
    body: 'The software is provided “as is” and “as available,” without warranties of any kind, express or implied, including merchantability, fitness for a particular purpose, accuracy, and non-infringement, to the fullest extent permitted by law.',
  },
  {
    title: "Limitation of liability",
    body: "To the fullest extent permitted by law, the developers are not liable for any indirect, incidental, or consequential damages, or for any loss arising from use of or reliance on the software or its outputs.",
  },
  {
    title: "Contact",
    body: "Questions about these terms can be raised through GitHub during the beta. A formal contact address will be published before general release.",
  },
];

export default function TermsPage() {
  return (
    <PageShell
      eyebrow="Legal"
      title="Terms"
      intro="These terms govern use of the Supra AI public beta. They are written conservatively and will be finalized before general release."
    >
      <DraftNotice />
      <div className="space-y-8">
        {sections.map((section) => (
          <section
            key={section.title}
            className="border-t border-supra-border pt-5"
          >
            <h2 className="text-xl text-supra-white">{section.title}</h2>
            <p className="measure-wide mt-3 text-base leading-[1.55] text-supra-muted">
              {section.body}
            </p>
          </section>
        ))}
        <section className="border-t border-supra-border pt-5">
          <h2 className="text-xl text-supra-white">
            Public GitHub Issues warning
          </h2>
          <div className="mt-4">
            <FeedbackWarning />
          </div>
        </section>
      </div>
    </PageShell>
  );
}
