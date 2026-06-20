import { CapabilityGrid } from "@/components/CapabilityGrid";
import { FinalCta } from "@/components/FinalCta";
import { Hero } from "@/components/Hero";
import { PrivacySection } from "@/components/PrivacySection";
import { SourceGroundingStack } from "@/components/SourceGroundingStack";

export default function Home() {
  return (
    <main>
      <Hero />
      <SourceGroundingStack />
      <CapabilityGrid />
      <PrivacySection />
      <FinalCta />
    </main>
  );
}
