describe('quarantine fixture', () => {
  it('append tags title', { tags: ['@other'] }, () => {
    cy.get('body');
  });
});
