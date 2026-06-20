import { CapabilityGrid } from "@/components/CapabilityGrid";
import { FinalCta } from "@/components/FinalCta";
import { Hero } from "@/components/Hero";
import { PrivacyArchitectureDiagram } from "@/components/PrivacyArchitectureDiagram";
import { SourceGroundingStack } from "@/components/SourceGroundingStack";

export default function Home() {
  return (
    <main>
      <Hero />
      <SourceGroundingStack />
      <CapabilityGrid />
      <PrivacyArchitectureDiagram />
      <FinalCta />
    </main>
  );
}
